"""Radio France podcast metadata from public pages; no JavaScript is executed."""
import re
import urllib.parse
from yt_dlp.extractor.common import InfoExtractor
from yt_dlp.utils import ExtractorError, js_to_json, parse_duration, unified_strdate

class LingoRadioFranceIE(InfoExtractor):
    IE_NAME = 'RadioFrance:LingoSave'
    _VALID_URL = r'https?://(?:www\.)?radiofrance\.fr/(?P<station>franceculture|franceinter|franceinfo|francemusique|fip|mouv)/podcasts/(?P<id>[^?#]+)(?:[?#].*)?$'

    @staticmethod
    def _nodes(value):
        if isinstance(value, dict):
            yield value
            for child in value.values():
                yield from LingoRadioFranceIE._nodes(child)
        elif isinstance(value, list):
            for child in value:
                yield from LingoRadioFranceIE._nodes(child)

    def _content(self, webpage, display_id):
        return self._search_json(r'\bcontent\s*:', webpage, 'podcast data', display_id,
                                 transform_source=js_to_json, fatal=False, default={})

    @staticmethod
    def _aod_url(episode_id):
        return 'https://www.radiofrance.fr/transistor/aod/' + urllib.parse.quote(episode_id, safe='')

    def _transcript(self, episode_id, aod):
        if not aod or aod.get('hasTranscript') is not True:
            return {}
        return {'fr': [{
            'url': self._aod_url(episode_id) + '/transcript',
            'ext': 'json',
            'name': 'Radio France – Transcription',
            'lingosave_radio_transcript': True,
        }]}

    def _aod(self, url, episode_id, title, duration=None):
        data = self._download_json(self._aod_url(episode_id), episode_id,
                                   note='Downloading programme audio sources')
        formats = []
        for index, source in enumerate(data.get('sources') or []):
            address = source.get('url')
            if not isinstance(address, str) or not address.startswith(('https://', 'http://')):
                continue
            high = 'hifi' in str(source.get('preset', '')).lower()
            formats.append({'format_id': f'radio-{index}', 'url': address, 'vcodec': 'none',
                            'acodec': 'mp3', 'ext': 'mp3', 'language': 'fr', 'abr': 192 if high else 128})
        if not formats:
            raise ExtractorError('网站尚未提供本集音源，或该节目暂时不可下载，请稍后重试。', expected=True)
        return {'id': episode_id, 'title': title or (data.get('metadata') or {}).get('secondLine') or episode_id,
                'duration': duration, 'webpage_url': url, 'formats': formats,
                'subtitles': self._transcript(episode_id, data),
                'lingosave_audio_only': True, 'language': 'fr'}

    def _episode(self, webpage, url, display_id, content):
        audio = next((node for node in self._yield_json_ld(webpage, display_id)
                      for node in self._nodes(node)
                      if node.get('@type') == 'AudioObject' and node.get('contentUrl')), None)
        if not audio and content.get('id'):
            return self._aod(url, content['id'], content.get('title'))
        if not audio:
            raise ExtractorError('本集尚未发布或网站尚未提供可下载的音源，请在节目发布后重试。', expected=True)
        audio_url = audio['contentUrl']
        if not isinstance(audio_url, str) or not audio_url.startswith(('https://', 'http://')):
            raise ExtractorError('Radio France 返回的音频地址无效。', expected=True)
        title = content.get('title') or audio.get('name') or self._og_search_title(webpage)
        title = title.strip()
        episode_id = content.get('id')
        media_id = episode_id or re.search(r'(\d{6,})(?:[/?#]|$)', url)
        if not isinstance(media_id, str):
            media_id = media_id.group(1) if media_id else display_id
        subtitles = {}
        if isinstance(episode_id, str) and episode_id and (
                self.get_param('writesubtitles') or self.get_param('listsubtitles')):
            aod = self._download_json(self._aod_url(episode_id), episode_id, fatal=False,
                                      note='Checking for an official Radio France transcript')
            subtitles = self._transcript(episode_id, aod)
        return {'id': media_id, 'title': title, 'webpage_url': url, 'subtitles': subtitles,
                'duration': parse_duration(audio.get('duration')),
                'upload_date': unified_strdate(audio.get('datePublished')),
                'lingosave_audio_only': True, 'language': 'fr',
                'formats': [{'format_id': 'radio-audio', 'url': audio_url,
                             'vcodec': 'none', 'acodec': 'mp3', 'ext': 'mp3', 'language': 'fr'}]}

    def _real_extract(self, url):
        match = self._match_valid_url(url)
        display_id = match.group('id').strip('/')
        webpage = self._download_webpage(url, display_id)
        content = self._content(webpage, display_id)
        if not content.get('expressions'):
            return self._episode(webpage, url, display_id, content)
        requested = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query).get('lingosave_episode', [None])[0]
        if requested:
            # Entries without a published page remain retriable without guessing media URLs.
            entry = next((e for e in content['expressions'].get('items', []) if e.get('id') == requested), None)
            href = ((entry or {}).get('titleProps') or {}).get('href')
            if href:
                return self.url_result(urllib.parse.urljoin('https://www.radiofrance.fr/', href), ie=self.ie_key())
            if entry:
                return self._aod(url, requested, (entry.get('titleProps') or {}).get('title') or entry.get('title'), entry.get('duration'))
            raise ExtractorError('所选节目已不在此系列中，请重新解析系列。', expected=True)
        metadata = content
        limit = self.get_param('playlistend')
        entries, seen, pages = [], set(), set()
        current_url = url
        for page_number in range(1, 201):
            if current_url in pages:
                raise ExtractorError('Radio France 节目分页重复，已停止以免遗漏节目。', expected=True)
            pages.add(current_url)
            expressions = content.get('expressions') or {}
            for episode in expressions.get('items') or []:
                eid = episode.get('id')
                if not eid or eid in seen:
                    continue
                seen.add(eid)
                props = episode.get('titleProps') or {}
                href = props.get('href') or episode.get('path')
                episode_url = urllib.parse.urljoin('https://www.radiofrance.fr/', href) if href else (
                    url.split('?', 1)[0] + '?lingosave_episode=' + urllib.parse.quote(eid))
                title = props.get('title') or episode.get('title') or props.get('text') or eid
                entries.append(self.url_result(episode_url, ie=self.ie_key(), video_id=eid,
                                               video_title=title.strip()))
                if limit and len(entries) >= limit:
                    break
            if limit and len(entries) >= limit:
                break
            next_page = expressions.get('next')
            if not next_page:
                break
            if isinstance(next_page, dict):
                next_page = next_page.get('href') or next_page.get('url')
            if isinstance(next_page, int) or (isinstance(next_page, str) and next_page.isdigit()):
                parsed = urllib.parse.urlsplit(url)
                query = urllib.parse.parse_qs(parsed.query)
                query['p'] = [str(next_page)]
                current_url = urllib.parse.urlunsplit(parsed._replace(query=urllib.parse.urlencode(query, doseq=True)))
            elif isinstance(next_page, str) and next_page.startswith(('/', 'https://www.radiofrance.fr/')):
                current_url = urllib.parse.urljoin(url, next_page)
            else:
                raise ExtractorError('Radio France 分页格式已变化，无法确认完整节目列表。', expected=True)
            webpage = self._download_webpage(current_url, display_id, note=f'Downloading podcast page {page_number + 1}')
            content = self._content(webpage, display_id)
        else:
            raise ExtractorError('Radio France 节目超过支持的 200 页，请分批添加。', expected=True)
        if not entries:
            raise ExtractorError('此系列暂无可识别的节目。', expected=True)
        return self.playlist_result(entries, metadata.get('id') or display_id,
                                    metadata.get('title') or self._og_search_title(webpage),
                                    playlist_count=metadata.get('expressionCount') or len(entries), lingosave_audio_only=True)