# Loaded only from the isolated test copy of yt-dlp, never the user's engine.
import json
import os
from yt_dlp_plugins.extractor.lingosave_radiofrance import LingoRadioFranceIE as _Production

class LingoRadioFranceIE(_Production):
    def _fixture(self):
        with open(os.environ['LINGOSAVE_RADIO_TEST_PAGES'], encoding='utf-8-sig') as stream:
            return json.load(stream)
    def _download_webpage(self, url, *args, **kwargs):
        return self._fixture()['pages'][url]
    def _download_json(self, url, *args, **kwargs):
        return self._fixture()['json'][url]
    def _transcript(self, episode_id, aod):
        subtitles = super()._transcript(episode_id, aod)
        if subtitles:
            subtitles['fr'][0]['url'] = self._fixture()['transcripts'][episode_id]
        return subtitles
