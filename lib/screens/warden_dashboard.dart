import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class WardenDashboard extends StatefulWidget {
  const WardenDashboard({super.key});

  @override
  State<WardenDashboard> createState() => _WardenDashboardState();
}

class _WardenDashboardState extends State<WardenDashboard> {
  final LatLng _initialPosition = const LatLng(31.5204, 74.3587); // Lahore
  final List<Marker> _markers = [];
  final MapController _mapController = MapController();

  @override
  void initState() {
    super.initState();

    _markers.addAll([
      const Marker(
        point: LatLng(31.5210, 74.3570),
        width: 40,
        height: 40,
        child: Icon(Icons.local_police, color: Colors.blue),
      ),
      const Marker(
        point: LatLng(31.5190, 74.3590),
        width: 40,
        height: 40,
        child: Icon(Icons.local_police, color: Colors.green),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Warden Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications),
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () {},
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Quick Stats
            SizedBox(
              height: 130,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _buildStatCard('Assigned Areas', '5', Colors.blue),
                  _buildStatCard('Pending Tasks', '2', Colors.orange),
                  _buildStatCard('Alerts', '1', Colors.red),
                  _buildStatCard('On Duty', '3', Colors.green),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // Emergency Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.warning, color: Colors.white),
                label: const Text('Send Emergency Alert'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  textStyle: const TextStyle(fontSize: 18),
                ),
                onPressed: () {},
              ),
            ),
            const SizedBox(height: 20),
            // Flutter Map
            SizedBox(
              height: 300,
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: _initialPosition,
                  initialZoom: 14,
                ),
                children: [
                  TileLayer(
  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  userAgentPackageName: 'com.example.traffic_control_app', // recommended
),

                  MarkerLayer(markers: _markers),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // Recent Activity
            const Text(
              'Recent Activity',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            _buildActivityTile('Marked attendance in Sector A', '2 mins ago'),
            _buildActivityTile('Reported congestion on Main Road', '10 mins ago'),
            _buildActivityTile('Requested backup for Sector B', '30 mins ago'),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard(String title, String value, Color color) {
    return Container(
      width: 140,
      margin: const EdgeInsets.only(right: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: Colors.white, fontSize: 16)),
          const Spacer(),
          Text(value,
              style: const TextStyle(
                  color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildActivityTile(String activity, String time) {
    return ListTile(
      leading: const Icon(Icons.check_circle, color: Colors.blue),
      title: Text(activity),
      subtitle: Text(time),
      dense: true,
      contentPadding: EdgeInsets.zero,
    );
  }
}
