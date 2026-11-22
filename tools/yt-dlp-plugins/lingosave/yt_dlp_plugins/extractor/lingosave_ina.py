"""Public INA podcast series and episodes."""

import re
from urllib.parse import urlsplit

from yt_dlp.extractor.common import InfoExtractor
from yt_dlp.utils import ExtractorError, extract_attributes


class LingoInaPodcastIE(InfoExtractor):
    IE_NAME = 'INAPodcasts:LingoSave'
    _VALID_URL = r'https?://podcasts\.ina\.fr/main/pub/(?P<kind>emission|podcast)/(?P<id>[0-9]+)(?:-[\w.%~-]+)?/?(?:[?#].*)?$'
    _SITE = 'https://podcasts.ina.fr'

    def _series(self, webpage, series_id):
        feed_url = f'https://api.octopus.saooti.com/rss/emission/{series_id}.rss'
        for tag in re.findall(r'<link\b[^>]*>', webpage, flags=re.I):
            attrs = extract_attributes(tag)
            if (attrs.get('type') == 'application/rss+xml' and attrs.get('href') == feed_url):
                break
        else:
            raise ExtractorError('INA 尚未提供此系列的公开 RSS。', expected=True)

        feed = self._download_xml(feed_url, series_id, note='Downloading INA series RSS')
        channel = feed.find('channel')
        if channel is None:
            raise ExtractorError('INA 系列 RSS 缺少节目列表。', expected=True)
        entries = []
        seen = set()
        for item in channel.findall('item'):
            link = (item.findtext('link') or '').strip()
            match = self._match_valid_url(link)
            if not match or match['kind'] != 'podcast':
                continue
            episode_id = match['id']
            if episode_id in seen:
                continue
            seen.add(episode_id)
            entries.append(self.url_result(
                f'{self._SITE}/main/pub/podcast/{episode_id}', self.ie_key(),
                video_id=episode_id, video_title=item.findtext('title') or episode_id))
        if not entries:
            raise ExtractorError('INA 系列没有可解析的公开分集。', expected=True)
        return self.playlist_result(entries, series_id, channel.findtext('title'),
                                    playlist_count=len(entries), lingosave_audio_only=True)

    def _real_extract(self, url):
        kind, media_id = self._match_valid_url(url).group('kind', 'id')
        page = f'{self._SITE}/main/pub/{kind}/{media_id}'
        webpage = self._download_webpage(page, media_id)
        if kind == 'emission':
            return self._series(webpage, media_id)

        audio = self._og_search_property(('audio:secure_url', 'audio'), webpage, default=None)
        source = urlsplit(audio or '')
        if (source.scheme != 'https' or source.netloc != 'api.octopus.saooti.com'
                or source.path != f'/podcast/download/{media_id}.mp3'):
            raise ExtractorError('INA 尚未提供此单集的公开 MP3 音源。', expected=True)
        title = self._og_search_title(webpage, default=None) or self._html_extract_title(webpage, default=media_id)
        return {
            'id': media_id,
            'title': title,
            'webpage_url': page,
            'formats': [{
                'format_id': 'ina-mp3', 'url': audio, 'ext': 'mp3',
                'vcodec': 'none', 'acodec': 'mp3', 'language': 'fr',
            }],
            'lingosave_audio_only': True,
        }
