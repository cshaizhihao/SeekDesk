sealed class ComposerStickerSelection {
  const ComposerStickerSelection();
}

final class OfficialStickerSelection extends ComposerStickerSelection {
  const OfficialStickerSelection(this.insertion);

  final String insertion;
}

final class CustomStickerSelection extends ComposerStickerSelection {
  const CustomStickerSelection({required this.groupID, required this.itemID});

  final String groupID;
  final String itemID;
}
