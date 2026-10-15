import 'bigquery/bigquery_driver.dart';
import 'cassandra/cassandra_driver.dart';
import 'mongodb/mongo_driver.dart';
import 'native_driver.dart';
import 'redis/redis_driver.dart';

/// Native drivers bundled with DbCraft.
const List<NativeDriver> nativeDrivers = [mongoDriver, redisDriver, cassandraDriver, bigQueryDriver];

NativeDriver? nativeDriverById(String id) {
  for (final d in nativeDrivers) {
    if (d.id == id) return d;
  }
  return null;
}
