class WeatherReading {
  final String siteId;
  final DateTime timestamp;
  final double rainfall1h;
  final double rainfall3h;
  final double temperature;
  final double humidity;
  final String weatherDescription;
  final double windSpeed;

  WeatherReading({
    required this.siteId,
    required this.timestamp,
    required this.rainfall1h,
    required this.rainfall3h,
    required this.temperature,
    required this.humidity,
    required this.weatherDescription,
    required this.windSpeed,
  });

  factory WeatherReading.fromMap(Map<String, dynamic> map) {
    return WeatherReading(
      siteId: map['siteId'] as String,
      timestamp: map['timestamp'] is DateTime
          ? map['timestamp'] as DateTime
          : (map['timestamp'] as dynamic).toDate() as DateTime,
      rainfall1h: (map['rainfall1h'] as num).toDouble(),
      rainfall3h: (map['rainfall3h'] as num).toDouble(),
      temperature: (map['temperature'] as num).toDouble(),
      humidity: (map['humidity'] as num).toDouble(),
      weatherDescription: map['weatherDescription'] as String,
      windSpeed: (map['windSpeed'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'siteId': siteId,
      'timestamp': timestamp,
      'rainfall1h': rainfall1h,
      'rainfall3h': rainfall3h,
      'temperature': temperature,
      'humidity': humidity,
      'weatherDescription': weatherDescription,
      'windSpeed': windSpeed,
    };
  }
}
