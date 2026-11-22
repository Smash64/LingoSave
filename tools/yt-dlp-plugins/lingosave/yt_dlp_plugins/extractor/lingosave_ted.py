"""Bridge TED's current videoPlayerData object to older yt-dlp releases."""
import json
from yt_dlp.extractor.ted import TedTalkIE as _TedTalkIE
__all__ = []

class _LingoTedTalkIE(_TedTalkIE, plugin_name='lingosave-compat'):
    def _search_nextjs_data(self, webpage, video_id, *args, **kwargs):
        data = super()._search_nextjs_data(webpage, video_id, *args, **kwargs)
        talk = ((data.get('props') or {}).get('pageProps') or {}).get('videoData') or {}
        player = talk.get('videoPlayerData')
        if not talk.get('playerData') and isinstance(player, dict):
            talk['playerData'] = json.dumps(player, ensure_ascii=False)
        return data