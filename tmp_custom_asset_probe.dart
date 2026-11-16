import 'package:wall_sync/services/custom_asset_service.dart';

Future<void> main() async {
  await CustomAssetService.instance.init();
  print('gifs=${CustomAssetService.instance.getGifs().length}');
  print('icons=${CustomAssetService.instance.getIcons().length}');
  print(CustomAssetService.instance.getGifs().first.fileName);
}
