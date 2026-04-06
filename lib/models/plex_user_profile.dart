/// Represents a Plex user's profile preferences
/// Fetched from https://clients.plex.tv/api/v2/user
bool? _readBoolSetting(dynamic value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true' || normalized == '1') return true;
    if (normalized == 'false' || normalized == '0') return false;
  }
  return null;
}

dynamic _readSetting(Map<String, dynamic> root, List<String> keys) {
  final normalizedKeys = keys.map((key) => key.toLowerCase()).toList(growable: false);
  final profile = root['profile'];
  final sources = <Map<String, dynamic>>[if (profile is Map<String, dynamic>) profile, root];

  for (final source in sources) {
    final normalizedSource = {for (final entry in source.entries) entry.key.toLowerCase(): entry.value};
    for (final key in normalizedKeys) {
      if (normalizedSource.containsKey(key)) {
        return normalizedSource[key];
      }
    }
  }

  final collections = <dynamic>[
    root['settings'],
    root['sharedSettings'],
    if (profile is Map<String, dynamic>) profile['settings'],
    if (profile is Map<String, dynamic>) profile['sharedSettings'],
  ];

  for (final collection in collections) {
    final match = _readSettingFromCollection(collection, normalizedKeys);
    if (match != null) return match;
  }

  return null;
}

dynamic _readSettingFromCollection(dynamic collection, List<String> normalizedKeys) {
  if (collection is Map<String, dynamic>) {
    final normalizedCollection = {for (final entry in collection.entries) entry.key.toLowerCase(): entry.value};
    for (final key in normalizedKeys) {
      if (normalizedCollection.containsKey(key)) {
        return normalizedCollection[key];
      }
    }
  }

  final list = collection is List ? collection : (collection == null ? const [] : [collection]);
  for (final item in list) {
    if (item is! Map) continue;

    final normalized = item.map((key, value) => MapEntry(key.toString(), value));
    final id = normalized['id']?.toString().toLowerCase();
    final settingKey = normalized['key']?.toString().toLowerCase();
    final label = normalized['label']?.toString().toLowerCase();

    if (normalizedKeys.contains(id) || normalizedKeys.contains(settingKey)) {
      return normalized['value'] ?? normalized['default'] ?? normalized['defaultValue'];
    }

    final haystacks = [id, settingKey, label].whereType<String>().toList(growable: false);
    final looksLikeThemeMusic =
        haystacks.any((value) => value.contains('theme') && value.contains('music')) ||
        haystacks.any((value) => value.contains('tv') && value.contains('theme'));
    if (looksLikeThemeMusic) {
      return normalized['value'] ?? normalized['default'] ?? normalized['defaultValue'];
    }
  }

  return null;
}

class PlexUserProfile {
  final bool autoSelectAudio;
  final int defaultAudioAccessibility;
  final String? defaultAudioLanguage;
  final List<String>? defaultAudioLanguages;
  final String? defaultSubtitleLanguage;
  final List<String>? defaultSubtitleLanguages;
  final int autoSelectSubtitle;
  final int defaultSubtitleAccessibility;
  final int defaultSubtitleForced;
  final int watchedIndicator;
  final int mediaReviewsVisibility;
  final List<String>? mediaReviewsLanguages;
  final bool playThemeMusic;

  PlexUserProfile({
    required this.autoSelectAudio,
    required this.defaultAudioAccessibility,
    this.defaultAudioLanguage,
    this.defaultAudioLanguages,
    this.defaultSubtitleLanguage,
    this.defaultSubtitleLanguages,
    required this.autoSelectSubtitle,
    required this.defaultSubtitleAccessibility,
    required this.defaultSubtitleForced,
    required this.watchedIndicator,
    required this.mediaReviewsVisibility,
    this.mediaReviewsLanguages,
    required this.playThemeMusic,
  });

  factory PlexUserProfile.fromJson(Map<String, dynamic> json) {
    final profile = json['profile'] as Map<String, dynamic>? ?? json;
    final playThemeMusicRaw = _readSetting(json, const ['playThemeMusic', 'themeMusic', 'playTvThemeMusic']);
    final playThemeMusic = _readBoolSetting(playThemeMusicRaw) ?? false;

    return PlexUserProfile(
      autoSelectAudio: profile['autoSelectAudio'] as bool? ?? true,
      defaultAudioAccessibility: profile['defaultAudioAccessibility'] as int? ?? 0,
      defaultAudioLanguage: profile['defaultAudioLanguage'] as String?,
      defaultAudioLanguages: profile['defaultAudioLanguages'] != null
          ? List<String>.from(profile['defaultAudioLanguages'] as List)
          : null,
      defaultSubtitleLanguage: profile['defaultSubtitleLanguage'] as String?,
      defaultSubtitleLanguages: profile['defaultSubtitleLanguages'] != null
          ? List<String>.from(profile['defaultSubtitleLanguages'] as List)
          : null,
      autoSelectSubtitle: profile['autoSelectSubtitle'] as int? ?? 0,
      defaultSubtitleAccessibility: profile['defaultSubtitleAccessibility'] as int? ?? 0,
      defaultSubtitleForced: profile['defaultSubtitleForced'] as int? ?? 1,
      watchedIndicator: profile['watchedIndicator'] as int? ?? 1,
      mediaReviewsVisibility: profile['mediaReviewsVisibility'] as int? ?? 0,
      mediaReviewsLanguages: profile['mediaReviewsLanguages'] != null
          ? List<String>.from(profile['mediaReviewsLanguages'] as List)
          : null,
      playThemeMusic: playThemeMusic,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'profile': {
        'autoSelectAudio': autoSelectAudio,
        'defaultAudioAccessibility': defaultAudioAccessibility,
        'defaultAudioLanguage': defaultAudioLanguage,
        'defaultAudioLanguages': defaultAudioLanguages,
        'defaultSubtitleLanguage': defaultSubtitleLanguage,
        'defaultSubtitleLanguages': defaultSubtitleLanguages,
        'autoSelectSubtitle': autoSelectSubtitle,
        'defaultSubtitleAccessibility': defaultSubtitleAccessibility,
        'defaultSubtitleForced': defaultSubtitleForced,
        'watchedIndicator': watchedIndicator,
        'mediaReviewsVisibility': mediaReviewsVisibility,
        'mediaReviewsLanguages': mediaReviewsLanguages,
        'playThemeMusic': playThemeMusic,
      },
    };
  }
}
