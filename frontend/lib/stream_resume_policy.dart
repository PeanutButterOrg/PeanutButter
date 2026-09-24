/// Whether the stream picker should open for this play action.
///
/// - Resume with a saved magnet → no picker (reuse torrent; avoids corrupting partial download).
/// - Play from beginning → always picker (fresh source).
/// - First play / no saved magnet → picker.
bool shouldShowStreamPicker({
  required bool fromBeginning,
  required bool preferResume,
  required bool hasSavedMagnet,
}) {
  if (fromBeginning) return true;
  if (preferResume && hasSavedMagnet) return false;
  return true;
}
