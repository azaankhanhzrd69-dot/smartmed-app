from dataclasses import dataclass

_BITRATES_MPEG1 = {
    1: (0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448),
    2: (0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384),
    3: (0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320),
}
_BITRATES_MPEG2 = {
    1: (0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256),
    2: (0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160),
    3: (0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160),
}
_SAMPLE_RATES = {
    3: (44100, 48000, 32000),
    2: (22050, 24000, 16000),
    0: (11025, 12000, 8000),
}


@dataclass(frozen=True)
class Mp3Info:
    duration_seconds: float
    frame_count: int


def _frame_info(data: bytes, offset: int) -> tuple[int, int, int, int] | None:
    if offset + 4 > len(data):
        return None
    header = int.from_bytes(data[offset : offset + 4], "big")
    if (header >> 21) & 0x7FF != 0x7FF:
        return None

    version = (header >> 19) & 0b11
    layer_bits = (header >> 17) & 0b11
    bitrate_index = (header >> 12) & 0b1111
    sample_index = (header >> 10) & 0b11
    if version == 1 or layer_bits == 0 or bitrate_index in (0, 15) or sample_index == 3:
        return None

    layer = 4 - layer_bits
    bitrate_table = _BITRATES_MPEG1 if version == 3 else _BITRATES_MPEG2
    bitrate = bitrate_table[layer][bitrate_index] * 1000
    sample_rate = _SAMPLE_RATES[version][sample_index]
    padding = (header >> 9) & 1
    if layer == 1:
        frame_size = (12 * bitrate // sample_rate + padding) * 4
        samples = 384
    else:
        multiplier = 144 if layer != 3 or version == 3 else 72
        frame_size = multiplier * bitrate // sample_rate + padding
        samples = 1152 if layer != 3 or version == 3 else 576

    if frame_size < 4 or offset + frame_size > len(data):
        return None
    return frame_size, sample_rate, samples, version


def inspect_mp3(data: bytes, max_duration_seconds: int = 120) -> Mp3Info:
    if len(data) < 8:
        raise ValueError("Audio is too short to contain a valid MP3 stream")

    offset = 0
    if data.startswith(b"ID3"):
        if len(data) < 10 or data[3] == 0xFF:
            raise ValueError("Malformed MP3 ID3 header")
        tag_size_bytes = data[6:10]
        if any(byte & 0x80 for byte in tag_size_bytes):
            raise ValueError("Malformed MP3 ID3 size")
        tag_size = (
            (tag_size_bytes[0] << 21)
            | (tag_size_bytes[1] << 14)
            | (tag_size_bytes[2] << 7)
            | tag_size_bytes[3]
        )
        offset = 10 + tag_size + (10 if data[5] & 0x10 else 0)
        if offset >= len(data):
            raise ValueError("MP3 ID3 tag contains no audio frames")

    first_frame = _frame_info(data, offset)
    if first_frame is None:
        raise ValueError("Audio does not contain a valid MP3 frame at its audio boundary")

    frame_count = 0
    duration = 0.0
    while (frame := _frame_info(data, offset)) is not None:
        frame_size, sample_rate, samples, _ = frame
        frame_count += 1
        duration += samples / sample_rate
        if duration > max_duration_seconds:
            raise ValueError(f"Audio exceeds the {max_duration_seconds}-second limit")
        offset += frame_size

    if frame_count < 2:
        raise ValueError("Audio must contain at least two complete MP3 frames")
    return Mp3Info(duration_seconds=duration, frame_count=frame_count)
