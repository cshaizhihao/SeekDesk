import 'package:flutter/widgets.dart';

enum DeskThemeFamily {
  classic('原色', '暖象牙', '石墨蓝', 'reader-light.png', 'reader-dark.png'),
  mountain('山岚', '湖上晨雾', '松林暮色', 'mist-lake.jpg', 'pine-dusk.jpg'),
  coast('海岸', '海玻璃', '午夜潮汐', 'sea-glass.jpg', 'midnight-tide.jpg');

  const DeskThemeFamily(
    this.title,
    this.lightTitle,
    this.darkTitle,
    this._lightImage,
    this._darkImage,
  );

  static const preference = 'workspace.themeFamily';
  final String title, lightTitle, darkTitle;
  final String _lightImage, _darkImage;

  static DeskThemeFamily fromSetting(Object? value) =>
      values.where((family) => family.name == value).firstOrNull ?? classic;

  String readingAsset(Brightness brightness) =>
      'assets/reader/${brightness == Brightness.dark ? _darkImage : _lightImage}';
}

class DeskThemeScope extends InheritedWidget {
  const DeskThemeScope({required this.family, required super.child, super.key});

  final DeskThemeFamily family;

  static DeskThemeFamily of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DeskThemeScope>()?.family ??
      DeskThemeFamily.classic;

  @override
  bool updateShouldNotify(DeskThemeScope oldWidget) =>
      oldWidget.family != family;
}
