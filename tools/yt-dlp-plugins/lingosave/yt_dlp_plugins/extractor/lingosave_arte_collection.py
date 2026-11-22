"""Retain ARTE's official show titles in its flat collection results."""

from yt_dlp.extractor.arte import ArteTVPlaylistIE as _ArteTVPlaylistIE

__all__ = []


class _LingoArteCollectionIE(_ArteTVPlaylistIE, plugin_name='lingosave-collection-titles'):
    def _download_json(self, url_or_request, *args, **kwargs):
        response = super()._download_json(url_or_request, *args, **kwargs)
        if (isinstance(url_or_request, str)
                and url_or_request.startswith('https://api.arte.tv/api/opa/v3/programs/')
                and isinstance(response, dict)):
            for program in response.get('programs') or []:
                if not isinstance(program, dict):
                    continue
                for show in program.get('videos') or []:
                    if isinstance(show, dict) and show.get('kind') == 'SHOW' and show.get('url'):
                        self._collection_shows[show['url']] = show
        return response

    def _real_extract(self, url):
        self._collection_shows = {}
        result = super()._real_extract(url)
        if self._collection_shows and result.get('entries') is not None:
            result['entries'] = self._with_show_titles(result['entries'], self._collection_shows)
        return result

    @staticmethod
    def _with_show_titles(entries, shows):
        for entry in entries:
            show = shows.get(entry.get('url')) or {}
            for field, source in (('id', 'programId'), ('title', 'title'), ('alt_title', 'subtitle')):
                if not entry.get(field) and show.get(source):
                    entry[field] = show[source]
            yield entry
