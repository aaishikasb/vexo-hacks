import asyncio
import json
import unittest
from collections import deque
from uuid import uuid4

from voca_pipeline import serve


class Native:
    def __init__(self):
        self.inbox = deque()
        self.events = asyncio.Queue()

    def emit(self, event):
        self.events.put_nowait(json.loads(event))

    def poll(self):
        return self.inbox.popleft() if self.inbox else None

    def send(self, event):
        self.inbox.append(json.dumps(event))


class PipelineChecks(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.native = Native()
        self.task = asyncio.create_task(serve(self.native))
        self.assertEqual((await self.event())['type'], 'ready')

    async def asyncTearDown(self):
        self.task.cancel()
        try:
            await self.task
        except asyncio.CancelledError:
            pass

    async def event(self):
        return await asyncio.wait_for(self.native.events.get(), 5)

    async def test_native_completion_required_and_stale_ack_ignored(self):
        request_id = str(uuid4())
        self.native.send(dict(type='speech', requestID=request_id, text='Test phrase.'))
        self.assertEqual((await self.event())['type'], 'speak')
        self.native.send(dict(type='playback', requestID=str(uuid4()), outcome='completed'))
        await asyncio.sleep(.05)
        self.assertTrue(self.native.events.empty())
        self.native.send(dict(type='playback', requestID=request_id, outcome='completed'))
        self.assertEqual((await self.event())['outcome'], 'completed')
        self.native.send(dict(type='playback', requestID=request_id, outcome='completed'))
        await asyncio.sleep(.05)
        self.assertTrue(self.native.events.empty())

    async def test_cancelled_playback_is_not_completed(self):
        request_id = str(uuid4())
        self.native.send(dict(type='speech', requestID=request_id, text='Test phrase.'))
        await self.event()
        self.native.send(dict(type='playback', requestID=request_id, outcome='cancelled'))
        self.assertEqual((await self.event())['outcome'], 'cancelled')

    async def test_band_transcription_does_not_wait_for_speech_and_never_speaks_it(self):
        speech_id = str(uuid4())
        self.native.send(dict(type='speech', requestID=speech_id, text='A cue.'))
        self.assertEqual((await self.event())['type'], 'speak')
        transcript_id = str(uuid4())
        self.native.send(dict(type='bandTranscript', requestID=transcript_id,
                              sessionID=str(uuid4()), text='My name is Alex.', timestamp='2026-11-14T12:00:00Z'))
        self.assertEqual(await self.event(), dict(type='bandTranscriptAccepted', requestID=transcript_id))
        self.assertTrue(self.native.events.empty())
        self.native.send(dict(type='playback', requestID=speech_id, outcome='completed'))
        self.assertEqual((await self.event())['outcome'], 'completed')

    async def test_practice_and_live_transcripts_keep_separate_acknowledgements(self):
        for kind, accepted in [('practiceTurn', 'practiceTurnAccepted'), ('bandTranscript', 'bandTranscriptAccepted')]:
            request_id = str(uuid4())
            self.native.send(dict(type=kind, requestID=request_id, sessionID=str(uuid4()),
                                  text='I enjoy hiking.', timestamp='2026-11-14T12:00:00Z'))
            self.assertEqual(await self.event(), dict(type=accepted, requestID=request_id))


if __name__ == '__main__':
    unittest.main()
