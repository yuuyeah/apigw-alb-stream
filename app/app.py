import asyncio
from functools import partial

import boto3
from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

app = FastAPI()
bedrock_runtime = boto3.client("bedrock-runtime", region_name="us-east-1")


class StreamRequest(BaseModel):
    message: str


@app.get("/health")
async def health():
    return {"status": "healthy"}


@app.post("/stream")
async def stream_response(req: StreamRequest):
    if not req.message:
        raise HTTPException(status_code=400, detail="message is required")

    async def generate():
        try:
            loop = asyncio.get_event_loop()

            # 同期的なBedrock呼び出しを別スレッドで実行
            response = await loop.run_in_executor(
                None,
                partial(
                    bedrock_runtime.converse_stream,
                    modelId="global.anthropic.claude-haiku-4-5-20251001-v1:0",
                    messages=[{"role": "user", "content": [{"text": req.message}]}],
                ),
            )

            stream = response.get("stream")
            if stream:
                for event in stream:
                    if "contentBlockDelta" in event:
                        delta = event["contentBlockDelta"]["delta"]
                        if "text" in delta:
                            yield delta["text"]
                            await asyncio.sleep(0)  # イベントループに制御を戻す
        except Exception as e:
            yield f"Error: {str(e)}"

    return StreamingResponse(
        generate(), media_type="text/plain", headers={"X-Accel-Buffering": "no"}
    )
