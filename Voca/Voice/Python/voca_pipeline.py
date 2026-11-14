"""On-device Pipecat speech adapter. Swift owns audio and completion truth."""
import asyncio
import json
from uuid import UUID

from pipecat.frames.frames import TTSSpeakFrame, TranscriptionFrame
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.worker import PipelineWorker
from pipecat.processors.frame_processor import FrameProcessor
from pipecat.workers.runner import WorkerRunner


class NativeSpeechAdapter(FrameProcessor):
    def __init__(self, emit):
        super().__init__()
        self.emit = emit
        self.pending = {}

    async def process_frame(self, frame, direction):
        await super().process_frame(frame, direction)
        if isinstance(frame, TranscriptionFrame):
            if frame.finalized:
                self.emit({'type': 'practiceTurnAccepted', 'requestID': frame.metadata['requestID']})
            return
        if not isinstance(frame, TTSSpeakFrame):
            await self.push_frame(frame, direction)
            return
        request_id = frame.metadata['requestID']
        future = asyncio.get_running_loop().create_future()
        self.pending[request_id] = future
        self.emit({'type': 'speak', 'requestID': request_id, 'text': frame.text})
        try:
            outcome = await asyncio.wait_for(future, timeout=30)
        except TimeoutError:
            outcome = 'failed'
            self.emit({'type': 'stop', 'requestID': request_id})
        except asyncio.CancelledError:
            outcome = 'cancelled'
        finally:
            self.pending.pop(request_id, None)
        # Only Swift's entire-playback acknowledgement can supply completed.
        self.emit({'type': 'terminal', 'requestID': request_id, 'outcome': outcome})

    def acknowledge(self, event):
        future = self.pending.get(event.get('requestID'))
        if future is None or future.done():
            return
        outcome = event.get('outcome')
        if outcome not in ('completed', 'cancelled', 'failed'):
            raise ValueError('Invalid playback outcome')
        future.set_result(outcome)


async def serve(native):
    emit = lambda event: native.emit(json.dumps(event))
    adapter = NativeSpeechAdapter(emit)
    worker = PipelineWorker(Pipeline([adapter]), enable_rtvi=False,
                            enable_turn_tracking=False, idle_timeout_secs=None)
    ready = asyncio.Event()

    @worker.event_handler('on_pipeline_started')
    async def started(worker, frame):
        ready.set()

    runner = WorkerRunner(handle_sigint=False, handle_sigterm=False)
    await runner.add_workers(worker)
    task = asyncio.create_task(runner.run())
    try:
        await asyncio.wait_for(ready.wait(), timeout=15)
        emit({'type': 'ready'})
        while not task.done():
            raw = native.poll()
            if raw is None:
                await asyncio.sleep(.015)
                continue
            event = json.loads(raw)
            if event['type'] == 'playback':
                adapter.acknowledge(event)
            elif event['type'] == 'practiceTurn':
                request_id = str(UUID(event['requestID']))
                session_id = str(UUID(event['sessionID']))
                text = event['text']
                if not isinstance(text, str) or not text.strip() or len(text) > 2000:
                    raise ValueError('Invalid practice turn')
                frame = TranscriptionFrame(text=text, user_id=session_id,
                                           timestamp=event['timestamp'], finalized=True)
                frame.metadata['requestID'] = request_id
                await worker.queue_frame(frame)
            elif event['type'] == 'speech':
                request_id = str(UUID(event['requestID']))
                text = event['text']
                if not isinstance(text, str) or not text.strip() or len(text) > 1000:
                    raise ValueError('Invalid speech text')
                frame = TTSSpeakFrame(text=text)
                frame.metadata['requestID'] = request_id
                await worker.queue_frame(frame)
            else:
                raise ValueError('Unknown native message')
        await task
    finally:
        await runner.cancel()
        await task


def run():
    import _pipecat_native
    from loguru import logger
    logger.remove()  # No transcript text in device logs.
    asyncio.run(serve(_pipecat_native))
