import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '/screens/emergency_alert_form.dart';
import 'login_screen.dart';

class WardenDashboard extends StatefulWidget {
  const WardenDashboard({super.key});

  @override
  State<WardenDashboard> createState() => _WardenDashboardState();
}

// Activity Model
class Activity {
  final int id;
  final String type;
  final String description;
  final DateTime timestamp;
  final String? location;
  final Map<String, dynamic>? metadata;

  Activity({
    required this.id,
    required this.type,
    required this.description,
    required this.timestamp,
    this.location,
    this.metadata,
  });

  factory Activity.fromJson(Map<String, dynamic> json) {
    return Activity(
      id: json['id'] ?? 0,
      type: json['type'] ?? 'unknown',
      description: json['description'] ?? '',
      timestamp: DateTime.parse(json['timestamp'] ?? DateTime.now().toIso8601String()),
      location: json['location'],
      metadata: json['metadata'],
    );
  }

  IconData get icon {
    switch (type.toLowerCase()) {
      case 'check_in':
      case 'check_out':
      case 'attendance':
        return Icons.access_time;
      case 'emergency':
      case 'alert':
        return Icons.warning;
      case 'patrol':
      case 'duty':
        return Icons.shield;
      case 'location':
        return Icons.location_on;
      case 'traffic':
        return Icons.traffic;
      case 'backup':
        return Icons.backup;
      case 'incident':
        return Icons.report_problem;
      default:
        return Icons.info;
    }
  }

  Color get color {
    switch (type.toLowerCase()) {
      case 'emergency':
      case 'alert':
        return Colors.red;
      case 'check_in':
      case 'attendance':
        return Colors.green;
      case 'check_out':
        return Colors.orange;
      case 'patrol':
      case 'duty':
        return Colors.blue;
      case 'traffic':
        return Colors.amber;
      case 'incident':
        return Colors.red[700]!;
      default:
        return Colors.grey;
    }
  }

  String get timeAgo {
    final now = DateTime.now();
    final difference = now.difference(timestamp);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes} min${difference.inMinutes == 1 ? '' : 's'} ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours} hour${difference.inHours == 1 ? '' : 's'} ago';
    } else {
      return '${difference.inDays} day${difference.inDays == 1 ? '' : 's'} ago';
    }
  }
}

class _WardenDashboardState extends State<WardenDashboard> {
  LatLng _initialPosition = const LatLng(31.5204, 74.3587);
  final List<Marker> _markers = [];
  late final MapController _mapController;

  bool _checkedIn = false;
  bool _isLoadingAttendance = false;
  Timer? _refreshTimer;
  Timer? _locationTimer;
  Timer? _activityTimer; // NEW: Activity refresh timer
  String? _token;
  String _attendanceStatus = 'Not Marked';
  bool _mapInitialized = false;
  Position? _currentPosition;
  StreamSubscription<Position>? _positionStream;

  // Duty Status Management
  bool _isOnDuty = false;
  bool _isLoadingDuty = false;
  DateTime? _lastLocationUpdate;
  double? _lastAccuracy;
  String _locationStatus = 'Unknown';

  // NEW: Activity Management
  List<Activity> _recentActivities = [];
  bool _isLoadingActivities = false;
  int _lastActivityId = 0;

  static const String _apiToken = '22|F9Oxn6DYcxdW42q8ESFCEOauSeQxEGCCHoUe4GdA77e88a50';

  // Dashboard Stats
  int _assignedAreas = 0;
  int _pendingTasks = 0;
  int _alerts = 0;
  int _onDuty = 0;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    await _loadToken();
    await _loadDutyStatus();
    await _checkLocationPermission();
    await _getCurrentLocation();
    await _fetchWardenLocations();
    await _fetchDashboardStats();
    await _checkCurrentAttendanceStatus();
    await _fetchRecentActivities(); // NEW: Load initial activities

    // Start refresh timer after initial load
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      _fetchWardenLocations();
      _fetchDashboardStats();
      // Only update location if on duty
      if (_isOnDuty) {
        _updateLocationToServer();
      }
    });

    // NEW: Start activity refresh timer (more frequent for real-time updates)
    _activityTimer = Timer.periodic(const Duration(seconds: 15), (timer) {
      _fetchRecentActivities();
    });

    // Start location tracking if on duty
    if (_isOnDuty) {
      _startLocationTracking();
    }
  }

  // NEW: Fetch recent activities from server
  Future<void> _fetchRecentActivities() async {
    if (_token == null) return;

    try {
      final response = await http.get(
        Uri.parse('http://192.168.18.65:8000/api/warden/activities'),
        headers: {
          'Authorization': 'Bearer $_token',
          'Accept': 'application/json',
        },
      );

      debugPrint('Activities response: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic> activitiesJson = data['activities'] ?? data['data'] ?? [];

        final List<Activity> newActivities = activitiesJson
            .map((json) => Activity.fromJson(json))
            .toList();

        // Sort by timestamp (newest first)
        newActivities.sort((a, b) => b.timestamp.compareTo(a.timestamp));

        if (!mounted) return;

        // Check for new activities to show notifications
        final newestIds = newActivities.take(3).map((a) => a.id).toSet();
        final currentIds = _recentActivities.take(3).map((a) => a.id).toSet();
        
        if (_recentActivities.isNotEmpty && !newestIds.intersection(currentIds).isEmpty) {
          final hasNewActivity = newActivities.any((activity) => 
            activity.id > _lastActivityId && activity.timestamp.isAfter(DateTime.now().subtract(const Duration(minutes: 2))));
          
          if (hasNewActivity) {
            final latestActivity = newActivities.first;
            _showActivityNotification(latestActivity);
          }
        }

        setState(() {
          _recentActivities = newActivities.take(10).toList(); // Keep last 10 activities
          if (newActivities.isNotEmpty) {
            _lastActivityId = newActivities.first.id;
          }
        });

        debugPrint('Loaded ${_recentActivities.length} activities');
      }
    } catch (e) {
      debugPrint('Error fetching activities: $e');
    }
  }

  // NEW: Log activity to server
  Future<void> _logActivity(String type, String description, {Map<String, dynamic>? metadata}) async {
    if (_token == null) return;

    try {
      final activityData = {
        'type': type,
        'description': description,
        'timestamp': DateTime.now().toIso8601String(),
        'location': _currentPosition != null 
            ? '${_currentPosition!.latitude.toStringAsFixed(6)}, ${_currentPosition!.longitude.toStringAsFixed(6)}'
            : null,
        'metadata': metadata,
      };

      final response = await http.post(
        Uri.parse('http://192.168.18.65:8000/api/warden/activities'),
        headers: {
          'Authorization': 'Bearer $_token',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode(activityData),
      );

      debugPrint('Activity log response: ${response.statusCode}');
      
      if (response.statusCode == 200 || response.statusCode == 201) {
        // Immediately refresh activities to show the new one
        _fetchRecentActivities();
      }
    } catch (e) {
      debugPrint('Error logging activity: $e');
    }
  }

  // NEW: Show notification for new activity
  void _showActivityNotification(Activity activity) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(activity.icon, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'New Activity: ${activity.description}',
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
        backgroundColor: activity.color,
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Future<void> _loadToken() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('token') ?? _apiToken;
    debugPrint('Loaded token: ${_token?.substring(0, 10)}...');
  }

  Future<void> _loadDutyStatus() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      _isOnDuty = prefs.getBool('warden_on_duty') ?? false;
    });
    debugPrint('Loaded duty status: $_isOnDuty');
  }

  Future<void> _saveDutyStatus() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool('warden_on_duty', _isOnDuty);
    debugPrint('Saved duty status: $_isOnDuty');
  }

  Future<void> _startLocationTracking() async {
    if (!_isOnDuty) {
      debugPrint('Not on duty - stopping location tracking');
      _stopLocationTracking();
      return;
    }

    debugPrint('Starting continuous location tracking...');
    
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        await _checkLocationPermission();
        return;
      }

      const LocationSettings locationSettings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
        timeLimit: Duration(seconds: 30),
      );

      _positionStream?.cancel();
      _positionStream = Geolocator.getPositionStream(locationSettings: locationSettings)
          .listen(
            (Position position) {
              if (_isOnDuty) {
                _handleLocationUpdate(position);
              }
            },
            onError: (error) {
              debugPrint('Location stream error: $error');
              setState(() {
                _locationStatus = 'Error: $error';
              });
            },
          );

      _locationTimer?.cancel();
      _locationTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
        if (_isOnDuty) {
          _getCurrentLocationForTracking();
        } else {
          timer.cancel();
        }
      });

      setState(() {
        _locationStatus = 'Tracking Active';
      });

    } catch (e) {
      debugPrint('Error starting location tracking: $e');
      setState(() {
        _locationStatus = 'Failed to start tracking';
      });
    }
  }

  void _stopLocationTracking() {
    debugPrint('Stopping location tracking...');
    _positionStream?.cancel();
    _positionStream = null;
    _locationTimer?.cancel();
    _locationTimer = null;
    
    setState(() {
      _locationStatus = 'Tracking Stopped';
    });
  }

  void _handleLocationUpdate(Position position) {
    debugPrint('Location update: ${position.latitude}, ${position.longitude}, Accuracy: ${position.accuracy}m');
    
    _currentPosition = position;
    _lastLocationUpdate = DateTime.now();
    _lastAccuracy = position.accuracy;

    final LatLng newPosition = LatLng(position.latitude, position.longitude);
    
    if (mounted) {
      setState(() {
        _initialPosition = newPosition;
        _locationStatus = 'Live Tracking';
        
        _markers.removeWhere((marker) {
          if (marker.child is Icon) {
            final icon = marker.child as Icon;
            return icon.color == Colors.red;
          }
          return false;
        });

        _markers.add(Marker(
          key: const Key('user_location'),
          point: newPosition,
          width: 50,
          height: 50,
          child: const Icon(Icons.location_pin, color: Colors.red, size: 40),
        ));
      });

      if (_mapInitialized) {
        _mapController.move(newPosition, 16.0);
      }
    }

    _updateLocationToServer();
  }

  Future<void> _getCurrentLocationForTracking() async {
    if (!_isOnDuty) return;

    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );
      
      _handleLocationUpdate(position);
    } catch (e) {
      debugPrint('Error getting location for tracking: $e');
      setState(() {
        _locationStatus = 'GPS Error';
      });
    }
  }

  // UPDATED: Toggle duty status with activity logging
  Future<void> _toggleDutyStatus() async {
    if (_isLoadingDuty) return;

    setState(() {
      _isLoadingDuty = true;
    });

    try {
      final newDutyStatus = !_isOnDuty;
      
      if (newDutyStatus) {
        await _checkLocationPermission();
        await _getCurrentLocation();
        _startLocationTracking();
        
        // Log duty start activity
        await _logActivity(
          'duty', 
          'Started duty shift', 
          metadata: {'action': 'duty_start', 'location_tracking': true}
        );
      } else {
        _stopLocationTracking();
        
        // Log duty end activity
        await _logActivity(
          'duty', 
          'Ended duty shift', 
          metadata: {'action': 'duty_end', 'location_tracking': false}
        );
      }

      setState(() {
        _isOnDuty = newDutyStatus;
      });

      await _saveDutyStatus();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_isOnDuty ? '✅ You are now ON DUTY - Location tracking started' : '🔴 You are now OFF DUTY - Location tracking stopped'),
            backgroundColor: _isOnDuty ? Colors.green : Colors.grey[700],
            duration: const Duration(seconds: 3),
          ),
        );
      }

    } catch (e) {
      debugPrint('Error toggling duty status: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update duty status: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingDuty = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _locationTimer?.cancel();
    _activityTimer?.cancel(); // NEW: Cancel activity timer
    _positionStream?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _checkCurrentAttendanceStatus() async {
    try {
      final response = await http.get(
        Uri.parse('http://192.168.18.65:8000/api/attendance/status'),
        headers: {
          'Authorization': 'Bearer $_token',
          'Accept': 'application/json',
        },
      );

      debugPrint('Attendance status response: ${response.statusCode}');
      debugPrint('Attendance status body: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (!mounted) return;
        
        setState(() {
          _checkedIn = data['status'] == 'in' || 
                     data['checked_in'] == true ||
                     data['is_checked_in'] == true;
          _attendanceStatus = _checkedIn ? 'Present' : 'Not Marked';
        });
      }
    } catch (e) {
      debugPrint('Error checking attendance status: $e');
    }
  }

  Future<void> _checkLocationPermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (!mounted) return;
      
      showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('Location Services Required'),
            content: const Text('Please enable location services to use this app. This is required for duty tracking and emergency response.'),
            actions: [
              TextButton(
                child: const Text('Cancel'),
                onPressed: () => Navigator.of(context).pop(),
              ),
              TextButton(
                child: const Text('Open Settings'),
                onPressed: () {
                  Navigator.of(context).pop();
                  Geolocator.openLocationSettings();
                },
              ),
            ],
          );
        },
      );
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Location permission denied. App functionality will be limited.'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      if (!mounted) return;
      
      showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('Location Permission Required'),
            content: const Text('Location permission has been permanently denied. Please enable it in app settings for full functionality.'),
            actions: [
              TextButton(
                child: const Text('Cancel'),
                onPressed: () => Navigator.of(context).pop(),
              ),
              TextButton(
                child: const Text('Open Settings'),
                onPressed: () {
                  Navigator.of(context).pop();
                  Geolocator.openAppSettings();
                },
              ),
            ],
          );
        },
      );
      return;
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      debugPrint('Getting current location...');
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );
      
      _handleLocationUpdate(position);

      if (!mounted) return;

      setState(() {
        _mapInitialized = true;
      });

      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted && _mapInitialized) {
          _mapController.move(LatLng(position.latitude, position.longitude), 16.0);
        }
      });

    } catch (e) {
      debugPrint('Error getting location: $e');
      if (!mounted) return;
      
      setState(() {
        _mapInitialized = true;
        _locationStatus = 'Location Failed';
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to get current location: $e'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  Future<void> _updateLocationToServer() async {
    if (!_isOnDuty || _currentPosition == null || _token == null) {
      debugPrint('Skipping location update - On duty: $_isOnDuty, Position: ${_currentPosition != null}, Token: ${_token != null}');
      return;
    }

    try {
      const double minLat = 23.0;
      const double maxLat = 37.5;
      const double minLng = 60.0;
      const double maxLng = 77.5;

      if (_currentPosition!.latitude < minLat || _currentPosition!.latitude > maxLat ||
          _currentPosition!.longitude < minLng || _currentPosition!.longitude > maxLng) {
        debugPrint('Location outside Pakistan bounds, skipping update');
        setState(() {
          _locationStatus = 'Location Out of Bounds';
        });
        return;
      }

      final response = await http.post(
        Uri.parse('http://192.168.18.65:8000/api/location/update'),
        headers: {
          'Authorization': 'Bearer $_token',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'latitude': _currentPosition!.latitude,
          'longitude': _currentPosition!.longitude,
          'accuracy': _currentPosition!.accuracy,
          'timestamp': DateTime.now().toIso8601String(),
          'on_duty': _isOnDuty,
        }),
      );

      debugPrint('Location update response: ${response.statusCode}');
      debugPrint('Location update body: ${response.body}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          debugPrint('Location updated successfully to server');
          setState(() {
            _locationStatus = _isOnDuty ? 'Live Tracking' : 'Tracking Stopped';
          });
        }
      } else {
        debugPrint('Failed to update location to server: ${response.body}');
        setState(() {
          _locationStatus = 'Update Failed';
        });
      }
    } catch (e) {
      debugPrint('Error updating location to server: $e');
      setState(() {
        _locationStatus = 'Network Error';
      });
    }
  }

  Future<void> _fetchWardenLocations() async {
    if (_token == null) return;
    
    try {
      final response = await http.get(
        Uri.parse('http://192.168.18.65:8000/api/location/wardens'),
        headers: {
          'Authorization': 'Bearer $_token',
          'Accept': 'application/json',
        },
      );

      debugPrint('Wardens locations response: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List locations = data['wardens_locations'] ?? data['data'] ?? [];

        debugPrint('Found ${locations.length} warden locations');

        if (!mounted) return;

        final userMarkers = _markers.where((marker) {
          if (marker.child is Icon) {
            final icon = marker.child as Icon;
            return icon.color == Colors.red;
          }
          return false;
        }).toList();

        final wardenMarkers = <Marker>[];
        for (int i = 0; i < locations.length; i++) {
          final loc = locations[i];
          try {
            final lat = double.parse(loc['latitude'].toString());
            final lng = double.parse(loc['longitude'].toString());
            final name = loc['name'] ?? loc['warden_name'] ?? 'Warden ${i + 1}';
            final onDuty = loc['on_duty'] ?? false;
            
            wardenMarkers.add(Marker(
              key: Key('warden_$i'),
              point: LatLng(lat, lng),
              width: 40,
              height: 40,
              child: Tooltip(
                message: '$name ${onDuty ? "(On Duty)" : "(Off Duty)"}',
                child: Icon(
                  Icons.local_police, 
                  color: onDuty ? Colors.blue : Colors.grey, 
                  size: 34
                ),
              ),
            ));
          } catch (e) {
            debugPrint('Error parsing warden location $i: $e');
          }
        }

        setState(() {
          _markers.clear();
          _markers.addAll(userMarkers);
          _markers.addAll(wardenMarkers);
        });

        debugPrint('Total markers on map: ${_markers.length}');
      }
    } catch (e) {
      debugPrint('Error fetching wardens locations: $e');
    }
  }

Future<void> _fetchDashboardStats() async {
  try {
    // Try the authenticated endpoint first
    final response = await http.get(
      Uri.parse('http://192.168.18.65:8000/api/warden/dashboard-stats'),
      headers: {
        'Authorization': 'Bearer $_token',
        'Accept': 'application/json',
      },
    );

    debugPrint('Dashboard stats response code: ${response.statusCode}');
    debugPrint('Dashboard stats response body: ${response.body}');

    // If authentication fails, try the public endpoint
    if (response.statusCode == 401) {
      debugPrint('Authentication failed, trying public endpoint');
      
      final publicResponse = await http.get(
        Uri.parse('http://192.168.18.65:8000/api/public-test-stats'),
        headers: {
          'Accept': 'application/json',
        },
      );
      
      debugPrint('Public stats response: ${publicResponse.statusCode}');
      
      if (publicResponse.statusCode == 200) {
        final data = jsonDecode(publicResponse.body);
        
        if (!mounted) return;
        
        setState(() {
          _assignedAreas = data['assigned_areas'] ?? 0;
          _pendingTasks = data['pending_tasks'] ?? 0;
          _alerts = data['alerts'] ?? 0;
          _onDuty = data['on_duty'] ?? 0;
        });
        return;
      }
    }

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);

      if (!mounted) return;

      setState(() {
        _assignedAreas = data['assigned_areas'] ?? 0;
        _pendingTasks = data['pending_tasks'] ?? 0;
        _alerts = data['alerts'] ?? 0;
        _onDuty = data['on_duty'] ?? 0;
      });
    }
  } catch (e) {
    debugPrint('Dashboard stats error: $e');
  }
}
  Future<void> _testTileLoading() async {
    try {
      final testUrls = [
        'https://tile.openstreetmap.org/1/0/0.png',
        'https://tile.openstreetmap.de/1/0/0.png',
        'https://a.basemaps.cartocdn.com/light_all/1/0/0.png',
      ];
      
      final results = <String, int>{};
      
      for (final url in testUrls) {
        try {
          final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
          results[url] = response.statusCode;
          debugPrint('Tile test - $url: ${response.statusCode}');
        } catch (e) {
          results[url] = 0;
          debugPrint('Tile test error - $url: $e');
        }
      }
      
      if (!mounted) return;
      
      final workingServers = results.values.where((code) => code == 200).length;
      final message = 'Tile servers: $workingServers/${testUrls.length} working';
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: workingServers > 0 ? Colors.green : Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      debugPrint('Tile loading test failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Network connectivity test failed: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  // UPDATED: Mark check-in with activity logging
  Future<bool> markCheckIn() async {
    try {
      debugPrint('Attempting check-in with current location...');
      
      Position? position = _currentPosition;
      try {
        position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 5),
        );
        _currentPosition = position;
      } catch (e) {
        debugPrint('Could not get fresh location, using cached: $e');
      }
      
      final requestBody = <String, dynamic>{};
      if (position != null) {
        requestBody['latitude'] = position.latitude;
        requestBody['longitude'] = position.longitude;
        requestBody['timestamp'] = DateTime.now().toIso8601String();
        debugPrint('Check-in location: ${position.latitude}, ${position.longitude}');
      }
      
      final response = await http.post(
        Uri.parse('http://192.168.18.65:8000/api/attendance/check-in'),
        headers: {
          'Authorization': 'Bearer $_token',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode(requestBody),
      );

      debugPrint('Check-in response status: ${response.statusCode}');
      debugPrint('Check-in response body: ${response.body}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final responseData = jsonDecode(response.body);
        
        if (responseData['success'] == true || 
            responseData['message']?.contains('successfully') == true ||
            responseData['message']?.contains('Already checked in') == true ||
            responseData['status'] == 'success') {
          
          // Log check-in activity
          await _logActivity(
            'check_in', 
            'Checked in for attendance',
            metadata: {
              'location': position != null 
                ? '${position.latitude.toStringAsFixed(6)}, ${position.longitude.toStringAsFixed(6)}'
                : 'Unknown',
              'accuracy': position?.accuracy,
            }
          );
          
// Keep this correct version:
if (responseData['message']?.contains('Already checked in') == true) {
  if (!mounted) return true;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('ℹ️ Already checked in today'), 
      backgroundColor: Colors.orange
    ),
  );
}
          return true;
        }
      }

      // Show specific error message if available
      if (response.statusCode >= 400) {
        final responseData = jsonDecode(response.body);
        final errorMessage = responseData['message'] ?? 'Unknown error occurred';
        
        if (!mounted) return false;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Check-in failed: $errorMessage'),
            backgroundColor: Colors.red,
          ),
        );
      }

      return false;
    } catch (e) {
      debugPrint('Check-in error: $e');
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Network error during check-in: $e'),
          backgroundColor: Colors.red,
        ),
      );
      return false;
    }
  }

  // UPDATED: Mark check-out with activity logging
  Future<bool> markCheckOut() async {
    try {
      debugPrint('Attempting check-out...');
      
      final response = await http.post(
        Uri.parse('http://192.168.18.65:8000/api/attendance/check-out'),
        headers: {
          'Authorization': 'Bearer $_token',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'timestamp': DateTime.now().toIso8601String(),
        }),
      );

      debugPrint('Check-out response status: ${response.statusCode}');
      debugPrint('Check-out response body: ${response.body}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final responseData = jsonDecode(response.body);
        
        if (responseData['success'] == true || 
            responseData['message']?.contains('successfully') == true ||
            responseData['status'] == 'success') {
          
          // Log check-out activity
          await _logActivity(
            'check_out', 
            'Checked out from attendance',
            metadata: {
              'location': _currentPosition != null 
                ? '${_currentPosition!.latitude.toStringAsFixed(6)}, ${_currentPosition!.longitude.toStringAsFixed(6)}'
                : 'Unknown',
            }
          );
          
          return true;
        }
      }

      return false;
    } catch (e) {
      debugPrint('Check-out error: $e');
      return false;
    }
  }

  Future<void> _logout() async {
    // Log logout activity
    await _logActivity(
      'logout', 
      'Logged out from system',
      metadata: {'session_end': DateTime.now().toIso8601String()}
    );
    
    // Stop location tracking before logout
    _stopLocationTracking();
    
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    await prefs.remove('name');
    await prefs.remove('email');
    await prefs.remove('warden_on_duty');

    if (!mounted) return;

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  void _showLocationDebugInfo() {
    String debugInfo = 'Location Debug Info:\n\n';
    debugInfo += 'On Duty: $_isOnDuty\n';
    debugInfo += 'Location Status: $_locationStatus\n';
    debugInfo += 'Current Position: ${_currentPosition?.latitude.toStringAsFixed(6)}, ${_currentPosition?.longitude.toStringAsFixed(6)}\n';
    debugInfo += 'Last Update: ${_lastLocationUpdate?.toString() ?? "Never"}\n';
    debugInfo += 'Accuracy: ${_lastAccuracy?.toStringAsFixed(1) ?? "Unknown"}m\n';
    debugInfo += 'Stream Active: ${_positionStream != null}\n';
    debugInfo += 'Timer Active: ${_locationTimer?.isActive ?? false}\n';
    debugInfo += 'Activities Count: ${_recentActivities.length}\n';
    debugInfo += 'Last Activity ID: $_lastActivityId\n';
    
    debugPrint('=== LOCATION DEBUG INFO ===');
    debugPrint(debugInfo);
    debugPrint('========================');
  }

  // NEW: Manual refresh activities
  Future<void> _refreshActivities() async {
    setState(() {
      _isLoadingActivities = true;
    });

    await _fetchRecentActivities();

    if (mounted) {
      setState(() {
        _isLoadingActivities = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🔄 Activities refreshed'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  // NEW: Clear activities (for testing)
  void _clearActivities() {
    setState(() {
      _recentActivities.clear();
      _lastActivityId = 0;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('🗑️ Activities cleared'),
        backgroundColor: Colors.orange,
        duration: Duration(seconds: 2),
      ),
    );
  }

  // NEW: Test activity generation (for demo purposes)
  Future<void> _generateTestActivity() async {
    final activities = [
      {'type': 'patrol', 'description': 'Started patrol in Sector A'},
      {'type': 'traffic', 'description': 'Reported traffic congestion on Main Street'},
      {'type': 'incident', 'description': 'Responded to minor incident'},
      {'type': 'alert', 'description': 'Issued safety alert to residents'},
      {'type': 'backup', 'description': 'Requested backup for crowd control'},
    ];

    final random = activities[DateTime.now().millisecond % activities.length];
    await _logActivity(random['type']!, random['description']!);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Warden Dashboard'),
        backgroundColor: Colors.deepPurple,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _fetchWardenLocations();
              _fetchDashboardStats();
              _refreshActivities(); // Refresh activities too
              if (_isOnDuty) {
                _getCurrentLocationForTracking();
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.bug_report),
            onPressed: _showLocationDebugInfo,
          ),
          IconButton(icon: const Icon(Icons.notifications), onPressed: () {}),
          IconButton(icon: const Icon(Icons.logout), onPressed: _logout),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.deepPurpleAccent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'Welcome, Warden! Here\'s your dashboard overview.',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.deepPurple),
                ),
              ),
              const SizedBox(height: 20),
              
              _buildDutyStatusCard(),
              const SizedBox(height: 16),
              
              _buildLocationStatusCard(),
              const SizedBox(height: 20),
              
              _buildStatsGrid(),
              const SizedBox(height: 10),
              const Divider(thickness: 2),
              const SizedBox(height: 20),
              _buildEmergencyButton(),
              const SizedBox(height: 20),
              _buildAttendanceButton(),
              const SizedBox(height: 12),
              _buildAttendanceChip(_attendanceStatus),
              const SizedBox(height: 24),
              _buildMap(),
              const SizedBox(height: 24),
              
              // UPDATED: Recent Activity Section with real-time functionality
              _buildRecentActivitySection(),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDutyStatusCard() {
    return Card(
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: _isOnDuty ? Colors.green.withOpacity(0.1) : Colors.grey.withOpacity(0.1),
        ),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Duty Status',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey[700],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _isOnDuty ? 'ON DUTY' : 'OFF DUTY',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: _isOnDuty ? Colors.green : Colors.grey[600],
                      ),
                    ),
                  ],
                ),
                _isLoadingDuty
                  ? const CircularProgressIndicator()
                  : Switch.adaptive(
                      value: _isOnDuty,
                      onChanged: (value) => _toggleDutyStatus(),
                      activeColor: Colors.green,
                      inactiveThumbColor: Colors.grey,
                    ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _isOnDuty ? Colors.green.withOpacity(0.1) : Colors.grey.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _isOnDuty ? Colors.green : Colors.grey,
                  width: 1,
                ),
              ),
              child: Text(
                _isOnDuty 
                  ? '🟢 Location tracking active - Your position is being shared'
                  : '🔴 Location tracking disabled - No position updates',
                style: TextStyle(
                  fontSize: 14,
                  color: _isOnDuty ? Colors.green[800] : Colors.grey[600],
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLocationStatusCard() {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.location_on,
                  color: _isOnDuty ? Colors.blue : Colors.grey,
                  size: 24,
                ),
                const SizedBox(width: 8),
                Text(
                  'Location Status',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey[800],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildLocationInfoRow('Status', _locationStatus, _getLocationStatusColor()),
            const SizedBox(height: 8),
            if (_currentPosition != null) ...[
              _buildLocationInfoRow(
                'Coordinates', 
                '${_currentPosition!.latitude.toStringAsFixed(6)}, ${_currentPosition!.longitude.toStringAsFixed(6)}',
                Colors.grey[600]!,
              ),
              const SizedBox(height: 8),
              _buildLocationInfoRow(
                'Accuracy', 
                _lastAccuracy != null 
                  ? '${_lastAccuracy!.toStringAsFixed(1)}m ${_getAccuracyIcon()}'
                  : 'Unknown',
                _getAccuracyColor(),
              ),
              const SizedBox(height: 8),
              _buildLocationInfoRow(
                'Last Update', 
                _lastLocationUpdate != null 
                  ? '${DateTime.now().difference(_lastLocationUpdate!).inSeconds}s ago'
                  : 'Never',
                Colors.grey[600]!,
              ),
            ] else ...[
              _buildLocationInfoRow('GPS', 'No location data', Colors.red),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLocationInfoRow(String label, String value, Color color) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey[600],
            fontWeight: FontWeight.w500,
          ),
        ),
        Flexible(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 14,
              color: color,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }

  Color _getLocationStatusColor() {
    switch (_locationStatus.toLowerCase()) {
      case 'live tracking':
        return Colors.green;
      case 'tracking active':
        return Colors.blue;
      case 'tracking stopped':
        return Colors.grey;
      case 'gps error':
      case 'location failed':
      case 'update failed':
      case 'network error':
        return Colors.red;
      case 'location out of bounds':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  Color _getAccuracyColor() {
    if (_lastAccuracy == null) return Colors.grey;
    if (_lastAccuracy! <= 10) return Colors.green;
    if (_lastAccuracy! <= 50) return Colors.orange;
    return Colors.red;
  }

  String _getAccuracyIcon() {
    if (_lastAccuracy == null) return '';
    if (_lastAccuracy! <= 10) return '🟢';
    if (_lastAccuracy! <= 50) return '🟡';
    return '🔴';
  }

  Widget _buildStatsGrid() {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 14,
      crossAxisSpacing: 14,
      childAspectRatio: 1.1,
      children: [
        _StatCard(title: 'Assigned Areas', value: '$_assignedAreas', color: Colors.blue),
        _StatCard(title: 'Pending Tasks', value: '$_pendingTasks', color: Colors.orange),
        _StatCard(title: 'Alerts', value: '$_alerts', color: Colors.red),
        _StatCard(title: 'On Duty', value: '$_onDuty', color: Colors.green),
      ],
    );
  }

  Widget _buildEmergencyButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        icon: const Icon(Icons.warning, color: Colors.white),
        label: const Text('Send Emergency Alert'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.red.shade700,
          padding: const EdgeInsets.symmetric(vertical: 18),
          textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 8,
        ),
        onPressed: () async {
          // Log emergency alert activity
          await _logActivity(
            'emergency', 
            'Initiated emergency alert',
            metadata: {'alert_type': 'manual', 'source': 'dashboard'}
          );
          
          if (!mounted) return;
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const EmergencyAlertForm(token: _apiToken)),
          );
        },
      ),
    );
  }

  Widget _buildAttendanceButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        icon: _isLoadingAttendance 
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
            )
          : Icon(_checkedIn ? Icons.logout : Icons.fingerprint, color: Colors.white),
        label: Text(
          _isLoadingAttendance 
            ? 'Processing...' 
            : (_checkedIn ? 'Check Out' : 'Mark Attendance (Check In)')
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: _checkedIn ? Colors.teal.shade700 : Colors.green.shade700,
          padding: const EdgeInsets.symmetric(vertical: 18),
          textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 6,
        ),
        onPressed: _isLoadingAttendance ? null : () async {
          if (!mounted) return;

          setState(() => _isLoadingAttendance = true);

          bool success = false;
          String operation = _checkedIn ? 'check-out' : 'check-in';
          
          if (_checkedIn) {
            success = await markCheckOut();
          } else {
            success = await markCheckIn();
          }

          if (!mounted) return;

          setState(() => _isLoadingAttendance = false);

          if (success) {
            setState(() {
              _checkedIn = !_checkedIn;
              _attendanceStatus = _checkedIn ? 'Present' : 'Not Marked';
            });
            
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(_checkedIn ? '✅ Attendance marked: Checked In' : '👋 Checked Out'),
                backgroundColor: _checkedIn ? Colors.green : Colors.grey[800],
              ),
            );
            
            _fetchDashboardStats();
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('❌ Failed to $operation. Check console for details.'),
                backgroundColor: Colors.red,
              ),
            );
          }
        },
      ),
    );
  }

  Widget _buildAttendanceChip(String text) {
    return Row(
      children: [
        Chip(
          avatar: Icon(
            _checkedIn ? Icons.check_circle : Icons.radio_button_unchecked,
            color: _checkedIn ? Colors.green : Colors.grey,
            size: 20,
          ),
          label: Text('Attendance: $text', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          backgroundColor: Colors.grey.shade200,
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      ],
    );
  }

  Widget _buildMap() {
    return Container(
      height: 320,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            if (!_mapInitialized)
              const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: Colors.deepPurple),
                    SizedBox(height: 16),
                    Text('Loading map...'),
                  ],
                ),
              )
            else
              FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: _initialPosition,
                  initialZoom: 14.0,
                  minZoom: 10.0,
                  maxZoom: 18.0,
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                  ),
                  cameraConstraint: CameraConstraint.contain(
                    bounds: LatLngBounds(
                      const LatLng(-85.05112878, -180.0),
                      const LatLng(85.05112878, 180.0),
                    ),
                  ),
                  onMapReady: () {
                    debugPrint('Map is ready! Center: $_initialPosition, Markers: ${_markers.length}');
                  },
                  onPositionChanged: (position, hasGesture) {
                    debugPrint('Map position changed: ${position.center}, Zoom: ${position.zoom}');
                  },
                ),
                children: [
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.example.traffic_control_app',
                    maxZoom: 18,
                    maxNativeZoom: 19,
                    tileSize: 256,
                    retinaMode: true,
                    tms: false,
                    additionalOptions: const {
                      'attribution': '© OpenStreetMap contributors',
                    },
                    errorTileCallback: (tile, error, stackTrace) {
                      debugPrint('Map tile error for ${tile.coordinates}: $error');
                    },
                    tileBuilder: (context, tileWidget, tile) {
                      return Stack(
                        children: [
                          Container(
                            color: Colors.grey[200],
                            child: const Center(
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                          ),
                          tileWidget,
                        ],
                      );
                    },
                    fallbackUrl: 'https://tile.openstreetmap.de/{z}/{x}/{y}.png',
                  ),
                  if (_markers.isNotEmpty)
                    MarkerLayer(
                      markers: _markers,
                      rotate: false,
                    ),
                ],
              ),
            if (_mapInitialized)
              Positioned(
                bottom: 12,
                right: 12,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FloatingActionButton(
                      mini: true,
                      backgroundColor: Colors.green,
                      heroTag: "fit_bounds",
                      onPressed: () {
                        if (_markers.isNotEmpty) {
                          final points = _markers.map((m) => m.point).toList();
                          final bounds = LatLngBounds.fromPoints(points);
                          _mapController.fitCamera(
                            CameraFit.bounds(
                              bounds: bounds, 
                              padding: const EdgeInsets.all(50)
                            )
                          );
                          debugPrint('Fitting map to ${points.length} markers');
                        }
                      },
                      child: const Icon(Icons.fit_screen, color: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    FloatingActionButton(
                      mini: true,
                      backgroundColor: Colors.deepPurple,
                      heroTag: "my_location",
                      onPressed: _getCurrentLocation,
                      child: const Icon(Icons.my_location, color: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    FloatingActionButton(
                      mini: true,
                      backgroundColor: Colors.orange,
                      heroTag: "refresh_map",
                      onPressed: () {
                        setState(() {
                          _mapInitialized = false;
                        });
                        Future.delayed(const Duration(milliseconds: 500), () {
                          if (mounted) {
                            setState(() {
                              _mapInitialized = true;
                            });
                          }
                        });
                      },
                      child: const Icon(Icons.refresh, color: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    FloatingActionButton(
                      mini: true,
                      backgroundColor: Colors.cyan,
                      heroTag: "test_tiles",
                      onPressed: _testTileLoading,
                      child: const Icon(Icons.network_check, color: Colors.white),
                    ),
                  ],
                ),
              ),
            if (_mapInitialized)
              Positioned(
                bottom: 12,
                left: 12,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FloatingActionButton(
                      mini: true,
                      backgroundColor: Colors.blue,
                      heroTag: "zoom_in",
                      onPressed: () {
                        final currentZoom = _mapController.camera.zoom;
                        final newZoom = (currentZoom + 1).clamp(10.0, 18.0);
                        _mapController.move(_mapController.camera.center, newZoom);
                        debugPrint('Zoomed in to level: $newZoom');
                      },
                      child: const Icon(Icons.zoom_in, color: Colors.white, size: 20),
                    ),
                    const SizedBox(height: 8),
                    FloatingActionButton(
                      mini: true,
                      backgroundColor: Colors.blue,
                      heroTag: "zoom_out",
                      onPressed: () {
                        final currentZoom = _mapController.camera.zoom;
                        final newZoom = (currentZoom - 1).clamp(10.0, 18.0);
                        _mapController.move(_mapController.camera.center, newZoom);
                        debugPrint('Zoomed out to level: $newZoom');
                      },
                      child: const Icon(Icons.zoom_out, color: Colors.white, size: 20),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: StreamBuilder<MapEvent>(
                        stream: _mapController.mapEventStream,
                        builder: (context, snapshot) {
                          final zoom = _mapController.camera.zoom.toStringAsFixed(1);
                          return Text(
                            'Zoom\n$zoom',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            if (_mapInitialized)
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Duty: ${_isOnDuty ? "ON" : "OFF"}',
                        style: TextStyle(
                          color: _isOnDuty ? Colors.green : Colors.red, 
                          fontSize: 12, 
                          fontWeight: FontWeight.bold
                        ),
                      ),
                      Text(
                        'Markers: ${_markers.length}',
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                      Text(
                        'Location: $_locationStatus',
                        style: TextStyle(color: _getLocationStatusColor(), fontSize: 10),
                      ),
                      if (_currentPosition != null)
                        Text(
                          'GPS: ✓ ${_lastAccuracy?.toStringAsFixed(0) ?? "?"}m',
                          style: TextStyle(color: _getAccuracyColor(), fontSize: 10, fontWeight: FontWeight.bold),
                        )
                      else
                        const Text(
                          'GPS: ✗ No Location',
                          style: TextStyle(color: Colors.red, fontSize: 10, fontWeight: FontWeight.bold),
                        ),
                    ],
                  ),
                ),
              ),
            if (_isOnDuty && _locationStatus == 'Live Tracking')
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.radio_button_checked, color: Colors.white, size: 14),
                      SizedBox(width: 4),
                      Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // NEW: Build Recent Activity Section with real-time functionality
  Widget _buildRecentActivitySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Recent Activity', 
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Live indicator
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.green, width: 1),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.circle, color: Colors.green, size: 8),
                      SizedBox(width: 4),
                      Text(
                        'LIVE',
                        style: TextStyle(
                          color: Colors.green,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Test activity button (for demo)
                IconButton(
                  icon: const Icon(Icons.add_circle_outline, color: Colors.blue),
                  onPressed: _generateTestActivity,
                  tooltip: 'Generate Test Activity',
                ),
                // Refresh button
                IconButton(
                  icon: _isLoadingActivities 
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, color: Colors.deepPurple),
                  onPressed: _isLoadingActivities ? null : _refreshActivities,
                  tooltip: 'Refresh Activities',
                ),
                // Debug menu
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, color: Colors.grey),
                  onSelected: (value) {
                    switch (value) {
                      case 'clear':
                        _clearActivities();
                        break;
                      case 'debug':
                        _showActivityDebugInfo();
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'clear',
                      child: Row(
                        children: [
                          Icon(Icons.clear_all, size: 20),
                          SizedBox(width: 8),
                          Text('Clear Activities'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'debug',
                      child: Row(
                        children: [
                          Icon(Icons.info_outline, size: 20),
                          SizedBox(width: 8),
                          Text('Debug Info'),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        
        // Activity count and status
        Row(
          children: [
            Chip(
              avatar: Icon(
                Icons.history,
                color: Colors.deepPurple,
                size: 16,
              ),
              label: Text('${_recentActivities.length} activities'),
              backgroundColor: Colors.deepPurple.withOpacity(0.1),
            ),
            const SizedBox(width: 8),
            if (_recentActivities.isNotEmpty)
              Chip(
                avatar: Icon(
                  Icons.access_time,
                  color: Colors.green,
                  size: 16,
                ),
                label: Text('Last: ${_recentActivities.first.timeAgo}'),
                backgroundColor: Colors.green.withOpacity(0.1),
              ),
          ],
        ),
        const SizedBox(height: 16),
        
        // Activities list
        if (_isLoadingActivities && _recentActivities.isEmpty)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Column(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Loading activities...'),
                ],
              ),
            ),
          )
        else if (_recentActivities.isEmpty)
          Card(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Icon(
                    Icons.history_outlined,
                    size: 48,
                    color: Colors.grey[400],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'No recent activities',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey[600],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Activities will appear here as you use the app',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[500],
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _generateTestActivity,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Generate Test Activity'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.deepPurple,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          Column(
            children: _recentActivities.asMap().entries.map((entry) {
              final index = entry.key;
              final activity = entry.value;
              return _buildActivityTile(activity, index == 0);
            }).toList(),
          ),
      ],
    );
  }

  // NEW: Build individual activity tile
  Widget _buildActivityTile(Activity activity, bool isLatest) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Card(
        elevation: isLatest ? 4 : 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: isLatest 
              ? Border.all(color: Colors.deepPurple.withOpacity(0.3), width: 2)
              : null,
          ),
          child: ListTile(
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: activity.color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                activity.icon, 
                color: activity.color,
                size: 24,
              ),
            ),
            title: Text(
              activity.description,
              style: TextStyle(
                fontWeight: isLatest ? FontWeight.bold : FontWeight.w600,
                fontSize: isLatest ? 16 : 14,
              ),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.access_time, size: 14, color: Colors.grey[600]),
                    const SizedBox(width: 4),
                    Text(
                      activity.timeAgo,
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 12,
                      ),
                    ),
                    if (activity.location != null) ...[
                      const SizedBox(width: 12),
                      Icon(Icons.location_on, size: 14, color: Colors.grey[600]),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          activity.location!,
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 12,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
                if (activity.metadata != null && activity.metadata!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    children: activity.metadata!.entries.take(2).map((entry) {
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.grey[200],
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${entry.key}: ${entry.value}',
                          style: const TextStyle(fontSize: 10),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ],
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (isLatest)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.green,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      'NEW',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  )
                else
                  const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.grey),
              ],
            ),
            onTap: () => _showActivityDetails(activity),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          ),
        ),
      ),
    );
  }

  // NEW: Show activity details dialog
  void _showActivityDetails(Activity activity) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(activity.icon, color: activity.color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Activity Details',
                  style: TextStyle(color: activity.color),
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildDetailRow('Type', activity.type.toUpperCase()),
                const SizedBox(height: 8),
                _buildDetailRow('Description', activity.description),
                const SizedBox(height: 8),
                _buildDetailRow('Time', activity.timestamp.toString()),
                const SizedBox(height: 8),
                _buildDetailRow('Time Ago', activity.timeAgo),
                if (activity.location != null) ...[
                  const SizedBox(height: 8),
                  _buildDetailRow('Location', activity.location!),
                ],
                if (activity.metadata != null && activity.metadata!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Additional Information:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  ...activity.metadata!.entries.map((entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: _buildDetailRow(entry.key, entry.value.toString()),
                  )),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  // NEW: Build detail row for activity dialog
  Widget _buildDetailRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            '$label:',
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              color: Colors.grey,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }

  // NEW: Show activity debug info
  void _showActivityDebugInfo() {
    String debugInfo = 'Activity Debug Info:\n\n';
    debugInfo += 'Total Activities: ${_recentActivities.length}\n';
    debugInfo += 'Last Activity ID: $_lastActivityId\n';
    debugInfo += 'Loading: $_isLoadingActivities\n';
    debugInfo += 'Activity Timer Active: ${_activityTimer?.isActive ?? false}\n';
    debugInfo += 'Refresh Interval: 15 seconds\n';
    
    if (_recentActivities.isNotEmpty) {
      debugInfo += '\nRecent Activities:\n';
      for (int i = 0; i < _recentActivities.take(3).length; i++) {
        final activity = _recentActivities[i];
        debugInfo += '${i + 1}. ${activity.type}: ${activity.description} (${activity.timeAgo})\n';
      }
    }
    
    debugPrint('=== ACTIVITY DEBUG INFO ===');
    debugPrint(debugInfo);
    debugPrint('=========================');

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Activity Debug Info'),
          content: SingleChildScrollView(
            child: Text(debugInfo),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final Color color;

  const _StatCard({
    required this.title,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: color.withOpacity(0.15),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(value, style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: color)),
            const SizedBox(height: 8),
            Text(title, style: TextStyle(fontSize: 17, color: color.withOpacity(0.8))),
          ],
        ),
      ),
    );
  }
}