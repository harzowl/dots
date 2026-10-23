import base64
import os

import cv2
import torch
from fastapi import FastAPI
from PIL import Image
from pydantic import BaseModel
from transformers import AutoModelForCausalLM, AutoProcessor
from pgsrip.formats.pgs import read_display_sets, read_items

import transformers.masking_utils as masking_utils

_original_create_causal_mask = masking_utils.create_causal_mask


def _create_causal_mask_compat(*args, **kwargs):
    if 'inputs_embeds' in kwargs:
        kwargs['input_embeds'] = kwargs.pop('inputs_embeds')
    return _original_create_causal_mask(*args, **kwargs)


masking_utils.create_causal_mask = _create_causal_mask_compat

MODEL = os.environ.get('PADDLE_OCR_MODEL', 'PaddlePaddle/PaddleOCR-VL')
PROMPT = os.environ.get('PADDLE_OCR_PROMPT', 'OCR:')
PORT = int(os.environ.get('PADDLE_OCR_PORT', '8765'))

app = FastAPI()
processor = AutoProcessor.from_pretrained(MODEL, trust_remote_code=True)
model = AutoModelForCausalLM.from_pretrained(
    MODEL,
    trust_remote_code=True,
    torch_dtype=torch.bfloat16,
    attn_implementation='sdpa',
    low_cpu_mem_usage=True,
).to('cuda').eval()


class OcrRequest(BaseModel):
    sup: str
    language: str = 'eng'


def srt_time(milliseconds):
    total = milliseconds // 1000
    hours, remainder = divmod(total, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f'{hours:02d}:{minutes:02d}:{seconds:02d},{milliseconds % 1000:03d}'


@app.get('/health')
def health():
    return {'status': 'ok'}


@app.post('/ocr')
def ocr(request: OcrRequest):
    data = base64.b64decode(request.sup)
    items = read_items(read_display_sets(data, 'request.sup'), 'request.sup')
    cues = []
    for item in items:
        bitmap = cv2.copyMakeBorder(item.bitmap, 8, 8, 8, 8, cv2.BORDER_CONSTANT, value=255)
        image = Image.fromarray(cv2.cvtColor(bitmap, cv2.COLOR_GRAY2RGB))
        messages = [{
            'role': 'user',
            'content': [
                {'type': 'image', 'image': image},
                {'type': 'text', 'text': PROMPT},
            ],
        }]
        inputs = processor.apply_chat_template(
            messages,
            tokenize=True,
            add_generation_prompt=True,
            return_dict=True,
            return_tensors='pt',
        ).to('cuda')
        with torch.inference_mode():
            output = model.generate(
                **inputs,
                max_new_tokens=256,
                do_sample=False,
                use_cache=True,
            )
        text = processor.batch_decode(output, skip_special_tokens=True)[0]
        if 'Assistant:' in text:
            text = text.split('Assistant:', 1)[1]
        text = text.strip()
        if text:
            cues.append((item.start, item.end, text))

    srt = []
    for index, (start, end, text) in enumerate(cues, 1):
        srt.append(str(index))
        srt.append(f'{srt_time(start)} --> {srt_time(end)}')
        srt.append(text)
        srt.append('')
    return {'srt': '\n'.join(srt)}


if __name__ == '__main__':
    import uvicorn

    uvicorn.run(app, host='0.0.0.0', port=PORT)
