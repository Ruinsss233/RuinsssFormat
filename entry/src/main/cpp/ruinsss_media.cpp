/*
 * Ruinsss格式快转 - native lossless audio extraction engine.
 *
 * The engine never decodes or re-encodes audio. It opens the video as an
 * OH_AVSource, selects the first audio track, and copies the compressed sample
 * buffers into a new container with OH_AVMuxer. That keeps the original audio
 * bit-for-bit, runs at roughly storage speed, and uses O(1) memory, so a 10 GB
 * video is handled exactly like a 10 MB one.
 */

#include <napi/native_api.h>

#include <hilog/log.h>

#include <multimedia/native_audio_channel_layout.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avcodec_audiocodec.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avdemuxer.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avmuxer.h>
#include <multimedia/player_framework/native_avsource.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>
#include <vector>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0xD005501
#define LOG_TAG "RuinsssMedia"

namespace {

constexpr int32_t kMinSampleBuffer = 256 * 1024;
constexpr int32_t kDefaultSampleBuffer = 4 * 1024 * 1024;
constexpr int32_t kMaxSampleBuffer = 32 * 1024 * 1024;

std::string JsonEscape(const std::string &value)
{
    std::string out;
    out.reserve(value.size() + 8);
    for (char ch : value) {
        switch (ch) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (static_cast<unsigned char>(ch) < 0x20) {
                    out += ' ';
                } else {
                    out += ch;
                }
                break;
        }
    }
    return out;
}

std::string Quote(const std::string &value)
{
    return "\"" + JsonEscape(value) + "\"";
}

std::string Number(int64_t value)
{
    return std::to_string(value);
}

std::string Number(int32_t value)
{
    return std::to_string(value);
}

std::string Number(double value)
{
    std::ostringstream stream;
    stream.setf(std::ios::fixed);
    stream.precision(2);
    stream << value;
    return stream.str();
}

bool IsMime(const std::string &mime, const char *expected)
{
    return expected != nullptr && mime == expected;
}

std::string CodecLabel(const std::string &mime)
{
    if (IsMime(mime, OH_AVCODEC_MIMETYPE_AUDIO_AAC)) return "AAC";
    if (IsMime(mime, OH_AVCODEC_MIMETYPE_AUDIO_MPEG)) return "MP3";
    if (IsMime(mime, OH_AVCODEC_MIMETYPE_AUDIO_FLAC)) return "FLAC";
    if (IsMime(mime, OH_AVCODEC_MIMETYPE_AUDIO_OPUS)) return "Opus";
    if (IsMime(mime, OH_AVCODEC_MIMETYPE_AUDIO_VORBIS)) return "Vorbis";
    if (IsMime(mime, OH_AVCODEC_MIMETYPE_AUDIO_ALAC)) return "ALAC";
    if (IsMime(mime, OH_AVCODEC_MIMETYPE_AUDIO_RAW)) return "PCM";
    if (IsMime(mime, OH_AVCODEC_MIMETYPE_AUDIO_AMR_NB) ||
        IsMime(mime, OH_AVCODEC_MIMETYPE_AUDIO_AMR_WB)) return "AMR";
    if (mime == "audio/ac3" || mime == "audio/eac3") return "Dolby";
    if (mime.empty()) return "未知音轨";
    return mime;
}

std::string VideoCodecLabel(const std::string &mime)
{
    if (mime == "video/avc" || mime == "video/h264") return "H.264";
    if (mime == "video/hevc" || mime == "video/h265") return "H.265";
    if (mime == "video/mp4v-es") return "MPEG-4";
    if (mime == "video/x-vnd.on2.vp8") return "VP8";
    if (mime == "video/x-vnd.on2.vp9") return "VP9";
    if (mime == "video/av01") return "AV1";
    if (mime.empty()) return "视频";
    return mime;
}

struct AudioInfo {
    bool present = false;
    uint32_t trackIndex = 0;
    std::string mime;
    std::string codec = "未知音轨";
    int32_t sampleRate = 0;
    int32_t channels = 0;
    int64_t bitrate = 0;
    int32_t profile = -1;
    int32_t adts = 0;
    int32_t channelLayout = 0;
    int32_t sampleFormat = 0;
    int32_t maxInputSize = 0;
    bool hasConfig = false;
    std::vector<uint8_t> codecConfig;
    std::string suggestedFormat = "none";
    std::string extension;
    bool canExtract = false;
    std::string reason;
};

struct VideoInfo {
    bool present = false;
    std::string mime;
    std::string codec = "视频";
    int32_t width = 0;
    int32_t height = 0;
    double frameRate = 0.0;
};

struct AudioReadResult {
    bool ok = false;
    std::string error;
};

bool ReadAudioInfo(OH_AVFormat *format, AudioInfo *info)
{
    if (format == nullptr || info == nullptr) {
        return false;
    }
    const char *mime = nullptr;
    if (!OH_AVFormat_GetStringValue(format, OH_MD_KEY_CODEC_MIME, &mime) || mime == nullptr) {
        return false;
    }
    info->present = true;
    info->mime = mime;
    info->codec = CodecLabel(info->mime);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_AUD_SAMPLE_RATE, &info->sampleRate);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_AUD_CHANNEL_COUNT, &info->channels);
    OH_AVFormat_GetLongValue(format, OH_MD_KEY_BITRATE, &info->bitrate);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_PROFILE, &info->profile);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_AAC_IS_ADTS, &info->adts);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_CHANNEL_LAYOUT, &info->channelLayout);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, &info->sampleFormat);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_MAX_INPUT_SIZE, &info->maxInputSize);

    uint8_t *config = nullptr;
    size_t configSize = 0;
    if (OH_AVFormat_GetBuffer(format, OH_MD_KEY_CODEC_CONFIG, &config, &configSize) &&
        config != nullptr && configSize > 0) {
        info->codecConfig.assign(config, config + configSize);
        info->hasConfig = true;
    }

    if (IsMime(info->mime, OH_AVCODEC_MIMETYPE_AUDIO_AAC)) {
        if (info->adts != 0) {
            info->suggestedFormat = "aac";
            info->extension = "aac";
            info->canExtract = true;
            info->reason = "";
        } else {
            info->suggestedFormat = "m4a";
            info->extension = "m4a";
            info->canExtract = true;
            info->reason = "";
        }
    } else if (IsMime(info->mime, OH_AVCODEC_MIMETYPE_AUDIO_MPEG)) {
        info->suggestedFormat = "mp3";
        info->extension = "mp3";
        info->canExtract = true;
        info->reason = "";
    } else if (IsMime(info->mime, OH_AVCODEC_MIMETYPE_AUDIO_FLAC)) {
        info->suggestedFormat = "flac";
        info->extension = "flac";
        info->canExtract = true;
        info->reason = "";
    } else if (IsMime(info->mime, OH_AVCODEC_MIMETYPE_AUDIO_OPUS) ||
               IsMime(info->mime, OH_AVCODEC_MIMETYPE_AUDIO_VORBIS)) {
        info->suggestedFormat = "ogg";
        info->extension = "ogg";
        info->canExtract = true;
        info->reason = "";
    } else {
        info->suggestedFormat = "none";
        info->extension = "";
        info->canExtract = false;
        info->reason = "当前音轨为 " + info->codec + "，V1.0 暂不支持直接封装";
    }
    return true;
}

void ReadVideoInfo(OH_AVFormat *format, VideoInfo *info)
{
    if (format == nullptr || info == nullptr) {
        return;
    }
    const char *mime = nullptr;
    if (!OH_AVFormat_GetStringValue(format, OH_MD_KEY_CODEC_MIME, &mime) || mime == nullptr) {
        return;
    }
    info->present = true;
    info->mime = mime;
    info->codec = VideoCodecLabel(info->mime);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_WIDTH, &info->width);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_HEIGHT, &info->height);
    OH_AVFormat_GetDoubleValue(format, OH_MD_KEY_FRAME_RATE, &info->frameRate);
}

std::string AudioJson(const AudioInfo &a)
{
    std::ostringstream out;
    out << "{\"present\":" << (a.present ? "true" : "false")
        << ",\"trackIndex\":" << a.trackIndex
        << ",\"mime\":" << Quote(a.mime)
        << ",\"codec\":" << Quote(a.codec)
        << ",\"sampleRate\":" << a.sampleRate
        << ",\"channels\":" << a.channels
        << ",\"bitrate\":" << a.bitrate
        << ",\"profile\":" << a.profile
        << ",\"adts\":" << a.adts
        << ",\"sampleFormat\":" << a.sampleFormat
        << ",\"hasConfig\":" << (a.hasConfig ? "true" : "false")
        << ",\"suggestedFormat\":" << Quote(a.suggestedFormat)
        << ",\"extension\":" << Quote(a.extension)
        << ",\"canExtract\":" << (a.canExtract ? "true" : "false")
        << ",\"reason\":" << Quote(a.reason) << "}";
    return out.str();
}

std::string VideoJson(const VideoInfo &v)
{
    std::ostringstream out;
    out << "{\"present\":" << (v.present ? "true" : "false")
        << ",\"mime\":" << Quote(v.mime)
        << ",\"codec\":" << Quote(v.codec)
        << ",\"width\":" << v.width
        << ",\"height\":" << v.height
        << ",\"frameRate\":" << Number(v.frameRate) << "}";
    return out.str();
}

std::string ProbeError(const std::string &error)
{
    AudioInfo empty;
    VideoInfo emptyVideo;
    std::ostringstream out;
    out << "{\"ok\":false,\"error\":" << Quote(error)
        << ",\"durationUs\":0,\"trackCount\":0,\"sizeBytes\":0"
        << ",\"audio\":" << AudioJson(empty)
        << ",\"video\":" << VideoJson(emptyVideo) << "}";
    return out.str();
}

std::string ProbeFd(int32_t fd, int64_t size)
{
    if (fd < 0) {
        return ProbeError("无效的文件描述符");
    }
    struct stat statBuf {};
    if (size <= 0 && fstat(fd, &statBuf) == 0) {
        size = static_cast<int64_t>(statBuf.st_size);
    }
    if (size <= 0) {
        return ProbeError("无法读取视频文件大小");
    }

    OH_AVSource *source = OH_AVSource_CreateWithFD(fd, 0, size);
    if (source == nullptr) {
        return ProbeError("无法解析这个视频，可能是格式不受支持或文件已损坏");
    }

    int32_t trackCount = 0;
    int64_t durationUs = 0;
    OH_AVFormat *sourceFormat = OH_AVSource_GetSourceFormat(source);
    if (sourceFormat == nullptr) {
        OH_AVSource_Destroy(source);
        return ProbeError("无法读取视频的媒体信息");
    }
    OH_AVFormat_GetIntValue(sourceFormat, OH_MD_KEY_TRACK_COUNT, &trackCount);
    OH_AVFormat_GetLongValue(sourceFormat, OH_MD_KEY_DURATION, &durationUs);
    OH_AVFormat_Destroy(sourceFormat);

    if (trackCount <= 0) {
        OH_AVSource_Destroy(source);
        return ProbeError("这个文件里没有可识别的媒体轨道");
    }

    AudioInfo audio;
    VideoInfo video;
    for (int32_t i = 0; i < trackCount; ++i) {
        OH_AVFormat *trackFormat = OH_AVSource_GetTrackFormat(source, static_cast<uint32_t>(i));
        if (trackFormat == nullptr) {
            continue;
        }
        int32_t trackType = -1;
        OH_AVFormat_GetIntValue(trackFormat, OH_MD_KEY_TRACK_TYPE, &trackType);
        if (trackType == MEDIA_TYPE_AUD && !audio.present) {
            if (ReadAudioInfo(trackFormat, &audio)) {
                audio.trackIndex = static_cast<uint32_t>(i);
            }
        } else if (trackType == MEDIA_TYPE_VID && !video.present) {
            ReadVideoInfo(trackFormat, &video);
        }
        OH_AVFormat_Destroy(trackFormat);
    }

    OH_AVSource_Destroy(source);

    if (!audio.present) {
        std::ostringstream out;
        out << "{\"ok\":false,\"error\":\"这个文件没有音频轨道\""
            << ",\"durationUs\":" << durationUs
            << ",\"trackCount\":" << trackCount
            << ",\"sizeBytes\":" << size
            << ",\"audio\":" << AudioJson(audio)
            << ",\"video\":" << VideoJson(video) << "}";
        return out.str();
    }

    std::ostringstream out;
    out << "{\"ok\":true,\"error\":\"\""
        << ",\"durationUs\":" << durationUs
        << ",\"trackCount\":" << trackCount
        << ",\"sizeBytes\":" << size
        << ",\"audio\":" << AudioJson(audio)
        << ",\"video\":" << VideoJson(video) << "}";
    return out.str();
}

struct ProgressState {
    std::mutex mutex;
    bool running = false;
    bool cancel = false;
    std::string state = "idle";
    std::string error;
    int64_t processedUs = 0;
    int64_t totalUs = 0;
    int64_t bytes = 0;
    std::chrono::steady_clock::time_point started = std::chrono::steady_clock::now();
};

ProgressState g_progress;
std::atomic<bool> g_busy {false};

void ResetProgress(int64_t totalUs)
{
    std::lock_guard<std::mutex> lock(g_progress.mutex);
    g_progress.running = true;
    g_progress.cancel = false;
    g_progress.state = "extracting";
    g_progress.error.clear();
    g_progress.processedUs = 0;
    g_progress.totalUs = totalUs;
    g_progress.bytes = 0;
    g_progress.started = std::chrono::steady_clock::now();
}

void UpdateProgress(int64_t processedUs, int64_t bytes)
{
    std::lock_guard<std::mutex> lock(g_progress.mutex);
    if (processedUs > g_progress.processedUs) {
        g_progress.processedUs = processedUs;
    }
    g_progress.bytes = bytes;
}

void FinishProgress(const std::string &state, const std::string &error, int64_t processedUs, int64_t bytes)
{
    std::lock_guard<std::mutex> lock(g_progress.mutex);
    g_progress.running = false;
    g_progress.state = state;
    g_progress.error = error;
    if (state == "done") {
        g_progress.processedUs = g_progress.totalUs;
        g_progress.bytes = bytes;
    } else if (processedUs > 0) {
        g_progress.processedUs = processedUs;
        g_progress.bytes = bytes;
    }
}

bool IsCancelled()
{
    std::lock_guard<std::mutex> lock(g_progress.mutex);
    return g_progress.cancel;
}

std::string ProgressJson()
{
    std::lock_guard<std::mutex> lock(g_progress.mutex);
    int64_t elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - g_progress.started).count();
    double percent = -1.0;
    if (g_progress.state == "done") {
        percent = 100.0;
    } else if (g_progress.totalUs > 0) {
        percent = static_cast<double>(g_progress.processedUs) * 100.0 /
                  static_cast<double>(g_progress.totalUs);
        percent = std::max(0.0, std::min(99.8, percent));
    }
    double speed = 0.0;
    if (elapsedMs > 0) {
        speed = static_cast<double>(g_progress.bytes) * 1000.0 / static_cast<double>(elapsedMs);
    }
    std::ostringstream out;
    out << "{\"state\":" << Quote(g_progress.state)
        << ",\"running\":" << (g_progress.running ? "true" : "false")
        << ",\"percent\":" << Number(percent)
        << ",\"processedUs\":" << g_progress.processedUs
        << ",\"totalUs\":" << g_progress.totalUs
        << ",\"bytes\":" << g_progress.bytes
        << ",\"elapsedMs\":" << elapsedMs
        << ",\"speedBps\":" << Number(speed)
        << ",\"error\":" << Quote(g_progress.error) << "}";
    return out.str();
}

enum class PcmKind { None, Wav, Aiff };

struct OutputSpec {
    OH_AVOutputFormat format = AV_OUTPUT_FORMAT_MP3;
    std::string mime;
    bool aac = false;
    bool adts = false;
    bool direct = false;
    bool transcode = false;
    PcmKind pcm = PcmKind::None;
};

bool ResolveOutput(const std::string &requested, const AudioInfo &audio, OutputSpec *spec, std::string *error)
{
    std::string format = requested;
    if (format.empty() || format == "auto") {
        if (IsMime(audio.mime, OH_AVCODEC_MIMETYPE_AUDIO_MPEG)) {
            format = "mp3";
        } else if (IsMime(audio.mime, OH_AVCODEC_MIMETYPE_AUDIO_FLAC)) {
            format = "flac";
        } else {
            format = "mp3";
        }
    }
    if (format == "mp3") {
        spec->format = AV_OUTPUT_FORMAT_MP3;
        spec->mime = OH_AVCODEC_MIMETYPE_AUDIO_MPEG;
        spec->direct = IsMime(audio.mime, OH_AVCODEC_MIMETYPE_AUDIO_MPEG);
        spec->transcode = !spec->direct;
        return true;
    }
    if (format == "flac") {
        spec->format = AV_OUTPUT_FORMAT_FLAC;
        spec->mime = OH_AVCODEC_MIMETYPE_AUDIO_FLAC;
        spec->direct = IsMime(audio.mime, OH_AVCODEC_MIMETYPE_AUDIO_FLAC);
        spec->transcode = !spec->direct;
        return true;
    }
    if (format == "m4a") {
        if (!IsMime(audio.mime, OH_AVCODEC_MIMETYPE_AUDIO_AAC) || audio.adts != 0) {
            *error = "输出格式与音轨不匹配";
            return false;
        }
        spec->format = AV_OUTPUT_FORMAT_M4A;
        spec->mime = OH_AVCODEC_MIMETYPE_AUDIO_AAC;
        spec->aac = true;
        spec->adts = false;
        spec->direct = true;
        return true;
    }
    if (format == "aac") {
        spec->format = AV_OUTPUT_FORMAT_AAC;
        spec->mime = OH_AVCODEC_MIMETYPE_AUDIO_AAC;
        spec->aac = true;
        spec->adts = true;
        spec->direct = IsMime(audio.mime, OH_AVCODEC_MIMETYPE_AUDIO_AAC) && audio.adts != 0;
        spec->transcode = !spec->direct;
        return true;
    }
    if (format == "wav" || format == "aiff") {
        spec->pcm = format == "wav" ? PcmKind::Wav : PcmKind::Aiff;
        spec->direct = false;
        spec->transcode = false;
        return true;
    }
    if (format == "ogg") {
        if (!IsMime(audio.mime, OH_AVCODEC_MIMETYPE_AUDIO_OPUS) &&
            !IsMime(audio.mime, OH_AVCODEC_MIMETYPE_AUDIO_VORBIS)) {
            *error = "OGG 输出只支持 Opus/Vorbis 音轨的无损转封装；系统不提供 Vorbis/Opus 编码器，无法从当前源生成 OGG";
            return false;
        }
        spec->format = AV_OUTPUT_FORMAT_OGG;
        spec->mime = audio.mime;
        spec->direct = true;
        return true;
    }
    *error = "不支持的输出格式";
    return false;
}

int32_t AacFrequencyIndex(int32_t sampleRate)
{
    switch (sampleRate) {
        case 96000: return 0;
        case 88200: return 1;
        case 64000: return 2;
        case 48000: return 3;
        case 44100: return 4;
        case 32000: return 5;
        case 24000: return 6;
        case 22050: return 7;
        case 16000: return 8;
        case 12000: return 9;
        case 11025: return 10;
        case 8000: return 11;
        case 7350: return 12;
        default: return -1;
    }
}

std::vector<uint8_t> MakeAacConfig(const AudioInfo &audio)
{
    int32_t frequencyIndex = AacFrequencyIndex(audio.sampleRate);
    if (frequencyIndex < 0 || audio.channels < 1 || audio.channels > 7) {
        return {};
    }
    // AudioSpecificConfig: audioObjectType=2 (AAC-LC), 4-bit frequency index,
    // 4-bit channel configuration, then three zero bits.
    uint16_t config = static_cast<uint16_t>((2 << 11) | (frequencyIndex << 7) | (audio.channels << 3));
    return {static_cast<uint8_t>((config >> 8) & 0xFF), static_cast<uint8_t>(config & 0xFF)};
}

struct MediaGuard {
    OH_AVSource *source = nullptr;
    OH_AVDemuxer *demuxer = nullptr;
    OH_AVMuxer *muxer = nullptr;
    OH_AVBuffer *buffer = nullptr;
    bool muxerStarted = false;

    ~MediaGuard()
    {
        if (buffer != nullptr) {
            OH_AVBuffer_Destroy(buffer);
        }
        if (muxer != nullptr) {
            if (muxerStarted) {
                OH_AVMuxer_Stop(muxer);
            }
            OH_AVMuxer_Destroy(muxer);
        }
        if (demuxer != nullptr) {
            OH_AVDemuxer_Destroy(demuxer);
        }
        if (source != nullptr) {
            OH_AVSource_Destroy(source);
        }
    }
};

struct ExtractParams {
    int32_t inputFd = -1;
    int32_t outputFd = -1;
    int64_t inputSize = 0;
    std::string format;
};

struct ExtractOutcome {
    bool ok = false;
    bool cancelled = false;
    std::string error;
    std::string format;
    int64_t bytes = 0;
    int64_t durationUs = 0;
    int64_t elapsedMs = 0;
};

std::string ErrorCodeText(const char *action, OH_AVErrCode code)
{
    std::ostringstream out;
    out << action << "（错误码 " << static_cast<int32_t>(code) << "）";
    return out.str();
}

struct EncodedPacket {
    std::vector<uint8_t> data;
    int64_t pts = 0;
};

// Decodes the first audio track to PCM and re-encodes it to MP3/FLAC. The
// decoder and encoder run in synchronous mode, so no callback threads are
// involved and cancellation is checked by the caller's extraction thread.
class Transcoder {
public:
    Transcoder(const ExtractParams &params, const AudioInfo &audio, const OutputSpec &spec, int64_t durationUs)
        : params_(params), audio_(audio), spec_(spec), durationUs_(durationUs) {}

    ~Transcoder()
    {
        if (encoder_ != nullptr) {
            if (encoderStarted_) {
                OH_AudioCodec_Stop(encoder_);
            }
            OH_AudioCodec_Destroy(encoder_);
        }
        if (decoder_ != nullptr) {
            if (decoderStarted_) {
                OH_AudioCodec_Stop(decoder_);
            }
            OH_AudioCodec_Destroy(decoder_);
        }
        if (muxBuffer_ != nullptr) {
            OH_AVBuffer_Destroy(muxBuffer_);
        }
        if (muxer_ != nullptr) {
            if (muxerStarted_) {
                OH_AVMuxer_Stop(muxer_);
            }
            OH_AVMuxer_Destroy(muxer_);
        }
        if (demuxer_ != nullptr) {
            OH_AVDemuxer_Destroy(demuxer_);
        }
        if (source_ != nullptr) {
            OH_AVSource_Destroy(source_);
        }
    }

    ExtractOutcome Run()
    {
        out_.format = params_.format;
        out_.durationUs = durationUs_;
        auto started = std::chrono::steady_clock::now();
        if (ftruncate(params_.outputFd, 0) != 0 || lseek(params_.outputFd, 0, SEEK_SET) < 0) {
            return Fail("无法写入保存位置，请重新选择一个文件夹");
        }
        source_ = OH_AVSource_CreateWithFD(params_.inputFd, 0, params_.inputSize);
        if (source_ == nullptr) {
            return Fail("无法解析这个视频，可能是格式不受支持或文件已损坏");
        }
        demuxer_ = OH_AVDemuxer_CreateWithSource(source_);
        if (demuxer_ == nullptr) {
            return Fail("无法创建音频解复用器");
        }
        if (OH_AVDemuxer_SelectTrackByID(demuxer_, audio_.trackIndex) != AV_ERR_OK) {
            return Fail("无法选择音频轨道");
        }
        if (!CreateDecoder() || !CreateEncoder()) {
            return out_;
        }
        muxer_ = OH_AVMuxer_Create(params_.outputFd, spec_.format);
        if (muxer_ == nullptr) {
            return Fail("无法创建输出文件，可能是保存位置不可写或格式不受支持");
        }
        int32_t capacity = audio_.maxInputSize > 0 ? audio_.maxInputSize : kDefaultSampleBuffer;
        capacity = std::max(kMinSampleBuffer, std::min(kMaxSampleBuffer, capacity));
        inputBuffer_ = OH_AVBuffer_Create(capacity);
        if (inputBuffer_ == nullptr) {
            return Fail("内存不足，无法创建音频缓冲区");
        }

        ResetProgress(durationUs_);
        int64_t lastInputPts = 0;
        bool inputEos = false;
        while (!inputEos) {
            if (IsCancelled()) {
                out_.cancelled = true;
                break;
            }
            OH_AVErrCode readResult = OH_AVDemuxer_ReadSampleBuffer(demuxer_, audio_.trackIndex, inputBuffer_);
            if (readResult != AV_ERR_OK) {
                return Fail(ErrorCodeText("读取音频数据失败", readResult));
            }
            OH_AVCodecBufferAttr attr {};
            OH_AVErrCode attrResult = OH_AVBuffer_GetBufferAttr(inputBuffer_, &attr);
            if (attrResult != AV_ERR_OK) {
                return Fail(ErrorCodeText("读取音频帧信息失败", attrResult));
            }
            if (attr.size > 0) {
                uint8_t *data = OH_AVBuffer_GetAddr(inputBuffer_);
                if (data == nullptr) {
                    return Fail("无法读取音频帧");
                }
                int64_t pts = attr.pts >= 0 ? attr.pts : lastInputPts;
                if (!PushToCodec(decoder_, data + attr.offset, static_cast<size_t>(attr.size), pts, 0)) {
                    return out_;
                }
                lastInputPts = pts;
                UpdateProgress(pts, out_.bytes);
            }
            if ((attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0) {
                if (!PushToCodec(decoder_, nullptr, 0, lastInputPts, AVCODEC_BUFFER_FLAGS_EOS)) {
                    return out_;
                }
                inputEos = true;
            }
            if (!DrainDecoder() || !DrainEncoder()) {
                return out_;
            }
            if (out_.cancelled) {
                break;
            }
        }

        for (int32_t i = 0; i < 2000 && !out_.cancelled && !decoderEos_; ++i) {
            if (!DrainDecoder() || !DrainEncoder()) {
                return out_;
            }
            if (!decoderEos_) {
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            }
        }
        if (!out_.cancelled && !decoderEos_) {
            return Fail("解码音频超时，视频可能已损坏");
        }
        if (!out_.cancelled && !FlushPcm()) {
            return out_;
        }
        if (!out_.cancelled && muxerStarted_) {
            OH_AVErrCode stopResult = OH_AVMuxer_Stop(muxer_);
            muxerStarted_ = false;
            if (stopResult != AV_ERR_OK) {
                return Fail(ErrorCodeText("完成封装失败", stopResult));
            }
        }
        if (!out_.cancelled && out_.error.empty()) {
            if (out_.bytes <= 0) {
                return Fail("没有读到音频数据，视频可能没有可提取的声音");
            }
            if (fsync(params_.outputFd) != 0) {
                OH_LOG_WARN(LOG_APP, "fsync transcoded output failed: %{public}d", errno);
            }
            out_.ok = true;
        }
        out_.elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - started).count();
        if (out_.cancelled) {
            FinishProgress("cancelled", "", lastInputPts, out_.bytes);
        } else if (out_.ok) {
            FinishProgress("done", "", durationUs_, out_.bytes);
        } else {
            FinishProgress("error", out_.error, lastInputPts, out_.bytes);
        }
        return out_;
    }

private:
    ExtractOutcome Fail(const std::string &error)
    {
        out_.error = error;
        FinishProgress("error", error, 0, out_.bytes);
        return out_;
    }

    bool FailBool(const std::string &error)
    {
        Fail(error);
        return false;
    }

    bool CreateDecoder()
    {
        OH_AVFormat *format = OH_AVFormat_CreateAudioFormat(audio_.mime.c_str(), audio_.sampleRate, audio_.channels);
        if (format == nullptr) {
            Fail("无法创建音频解码配置");
            return false;
        }
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUD_SAMPLE_RATE, audio_.sampleRate);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUD_CHANNEL_COUNT, audio_.channels);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, SAMPLE_S16LE);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_ENABLE_SYNC_MODE, 1);
        if (audio_.hasConfig) {
            OH_AVFormat_SetBuffer(format, OH_MD_KEY_CODEC_CONFIG, audio_.codecConfig.data(), audio_.codecConfig.size());
        }
        if (audio_.adts != 0) {
            OH_AVFormat_SetIntValue(format, OH_MD_KEY_AAC_IS_ADTS, 1);
        }
        decoder_ = OH_AudioCodec_CreateByMime(audio_.mime.c_str(), false);
        if (decoder_ == nullptr) {
            OH_AVFormat_Destroy(format);
            Fail("当前音轨的解码器不可用");
            return false;
        }
        OH_AVErrCode result = OH_AudioCodec_Configure(decoder_, format);
        OH_AVFormat_Destroy(format);
        if (result != AV_ERR_OK) {
            Fail(ErrorCodeText("无法配置音频解码器", result));
            return false;
        }
        result = OH_AudioCodec_Prepare(decoder_);
        if (result != AV_ERR_OK) {
            Fail(ErrorCodeText("无法准备音频解码器", result));
            return false;
        }
        result = OH_AudioCodec_Start(decoder_);
        if (result != AV_ERR_OK) {
            Fail(ErrorCodeText("无法启动音频解码器", result));
            return false;
        }
        decoderStarted_ = true;
        return true;
    }

    bool CreateEncoder()
    {
        OH_AVFormat *format = OH_AVFormat_CreateAudioFormat(spec_.mime.c_str(), audio_.sampleRate, audio_.channels);
        if (format == nullptr) {
            Fail("无法创建音频编码配置");
            return false;
        }
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, SAMPLE_S16LE);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_ENABLE_SYNC_MODE, 1);
        int64_t layout = audio_.channels == 1 ? static_cast<int64_t>(CH_LAYOUT_MONO) :
            (audio_.channels == 2 ? static_cast<int64_t>(CH_LAYOUT_STEREO) : 0);
        if (layout != 0) {
            OH_AVFormat_SetLongValue(format, OH_MD_KEY_CHANNEL_LAYOUT, layout);
        }
        if (spec_.format == AV_OUTPUT_FORMAT_MP3) {
            OH_AVFormat_SetLongValue(format, OH_MD_KEY_BITRATE, 320000);
        } else if (spec_.format == AV_OUTPUT_FORMAT_AAC) {
            OH_AVFormat_SetLongValue(format, OH_MD_KEY_BITRATE, 192000);
            OH_AVFormat_SetIntValue(format, OH_MD_KEY_PROFILE, AAC_PROFILE_LC);
            OH_AVFormat_SetIntValue(format, OH_MD_KEY_AAC_IS_ADTS, 1);
        } else if (spec_.format == AV_OUTPUT_FORMAT_FLAC) {
            // FLAC's native encoder requires a target bitrate and, on older
            // system versions, the legacy "bits per coded sample" flag. The
            // latter is documented to return AV_ERR_INVALID_VAL when omitted
            // before API 20, which surfaced as "无法配置音频编码器".
            OH_AVFormat_SetLongValue(format, OH_MD_KEY_BITRATE,
                audio_.channels == 1 ? 130500 : 261000);
            OH_AVFormat_SetIntValue(format, OH_MD_KEY_BITS_PER_CODED_SAMPLE, 1);
            OH_AVFormat_SetLongValue(format, OH_MD_KEY_COMPLIANCE_LEVEL, 0);
        }
        encoder_ = OH_AudioCodec_CreateByMime(spec_.mime.c_str(), true);
        if (encoder_ == nullptr) {
            OH_AVFormat_Destroy(format);
            Fail("当前输出格式的编码器不可用");
            return false;
        }
        OH_AVErrCode result = OH_AudioCodec_Configure(encoder_, format);
        OH_AVFormat_Destroy(format);
        if (result != AV_ERR_OK) {
            Fail(ErrorCodeText("无法配置音频编码器", result));
            return false;
        }
        result = OH_AudioCodec_Prepare(encoder_);
        if (result != AV_ERR_OK) {
            Fail(ErrorCodeText("无法准备音频编码器", result));
            return false;
        }
        result = OH_AudioCodec_Start(encoder_);
        if (result != AV_ERR_OK) {
            Fail(ErrorCodeText("无法启动音频编码器", result));
            return false;
        }
        encoderStarted_ = true;
        return true;
    }

    bool IsRetry(OH_AVErrCode code) const
    {
        return code == AV_ERR_TRY_AGAIN_LATER;
    }

    bool PushToCodec(OH_AVCodec *codec, const uint8_t *data, size_t size, int64_t pts, uint32_t flags)
    {
        uint32_t index = 0;
        OH_AVErrCode query = AV_ERR_TRY_AGAIN_LATER;
        for (int32_t i = 0; i < 200; ++i) {
            query = OH_AudioCodec_QueryInputBuffer(codec, &index, 10000);
            if (query == AV_ERR_OK) {
                break;
            }
            if (!IsRetry(query)) {
                Fail(ErrorCodeText("等待音频输入缓冲区失败", query));
                return false;
            }
        }
        if (query != AV_ERR_OK) {
            Fail("音频处理超时");
            return false;
        }
        OH_AVBuffer *buffer = OH_AudioCodec_GetInputBuffer(codec, index);
        if (buffer == nullptr) {
            Fail("无法获取音频输入缓冲区");
            return false;
        }
        int32_t capacity = OH_AVBuffer_GetCapacity(buffer);
        if (size > static_cast<size_t>(capacity)) {
            Fail("音频帧大于缓冲区容量");
            return false;
        }
        if (size > 0) {
            uint8_t *addr = OH_AVBuffer_GetAddr(buffer);
            if (addr == nullptr) {
                Fail("无法写入音频输入缓冲区");
                return false;
            }
            memcpy(addr, data, size);
        }
        OH_AVCodecBufferAttr attr {};
        attr.pts = pts;
        attr.size = static_cast<int32_t>(size);
        attr.offset = 0;
        attr.flags = flags;
        if (OH_AVBuffer_SetBufferAttr(buffer, &attr) != AV_ERR_OK) {
            Fail("无法设置音频输入帧");
            return false;
        }
        OH_AVErrCode result = OH_AudioCodec_PushInputBuffer(codec, index);
        if (result != AV_ERR_OK) {
            Fail(ErrorCodeText("提交音频输入帧失败", result));
            return false;
        }
        return true;
    }

    static int16_t FloatToS16(float value)
    {
        value = std::max(-1.0f, std::min(1.0f, value));
        return static_cast<int16_t>(std::lrint(value * 32767.0f));
    }

    void AppendPcm(const uint8_t *data, int32_t size)
    {
        if (size <= 0) {
            return;
        }
        if (pcmFormat_ == SAMPLE_F32LE) {
            size_t samples = static_cast<size_t>(size) / sizeof(float);
            size_t base = pcm_.size();
            pcm_.resize(base + samples * sizeof(int16_t));
            auto *dst = reinterpret_cast<int16_t *>(pcm_.data() + base);
            for (size_t i = 0; i < samples; ++i) {
                float value = 0.0f;
                memcpy(&value, data + i * sizeof(float), sizeof(float));
                dst[i] = FloatToS16(value);
            }
        } else if (pcmFormat_ == SAMPLE_S32LE) {
            size_t samples = static_cast<size_t>(size) / sizeof(int32_t);
            size_t base = pcm_.size();
            pcm_.resize(base + samples * sizeof(int16_t));
            auto *dst = reinterpret_cast<int16_t *>(pcm_.data() + base);
            for (size_t i = 0; i < samples; ++i) {
                int32_t value = 0;
                memcpy(&value, data + i * sizeof(int32_t), sizeof(int32_t));
                dst[i] = static_cast<int16_t>(value >> 16);
            }
        } else if (pcmFormat_ == SAMPLE_S24LE) {
            size_t samples = static_cast<size_t>(size) / 3;
            size_t base = pcm_.size();
            pcm_.resize(base + samples * sizeof(int16_t));
            auto *dst = reinterpret_cast<int16_t *>(pcm_.data() + base);
            for (size_t i = 0; i < samples; ++i) {
                int32_t value = data[i * 3] | (data[i * 3 + 1] << 8) | (data[i * 3 + 2] << 16);
                if ((value & 0x800000) != 0) {
                    value |= ~0xFFFFFF;
                }
                dst[i] = static_cast<int16_t>(value >> 8);
            }
        } else if (pcmFormat_ == SAMPLE_U8) {
            size_t base = pcm_.size();
            pcm_.resize(base + static_cast<size_t>(size) * sizeof(int16_t));
            auto *dst = reinterpret_cast<int16_t *>(pcm_.data() + base);
            for (int32_t i = 0; i < size; ++i) {
                dst[i] = static_cast<int16_t>((static_cast<int32_t>(data[i]) - 128) << 8);
            }
        } else {
            pcm_.insert(pcm_.end(), data, data + size);
        }
    }

    bool DrainDecoder()
    {
        while (true) {
            uint32_t index = 0;
            OH_AVErrCode result = OH_AudioCodec_QueryOutputBuffer(decoder_, &index, 0);
            if (IsRetry(result)) {
                return true;
            }
            if (result != AV_ERR_OK) {
                Fail(ErrorCodeText("读取解码后的音频失败", result));
                return false;
            }
            OH_AVBuffer *buffer = OH_AudioCodec_GetOutputBuffer(decoder_, index);
            if (buffer == nullptr) {
                Fail("无法获取解码后的音频缓冲区");
                return false;
            }
            OH_AVCodecBufferAttr attr {};
            if (OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK) {
                OH_AudioCodec_FreeOutputBuffer(decoder_, index);
                Fail("无法读取解码帧信息");
                return false;
            }
            if (!decoderFormatRead_) {
                OH_AVFormat *desc = OH_AudioCodec_GetOutputDescription(decoder_);
                if (desc != nullptr) {
                    int32_t value = 0;
                    if (OH_AVFormat_GetIntValue(desc, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, &value) && value > 0) {
                        pcmFormat_ = value;
                    }
                    OH_AVFormat_Destroy(desc);
                }
                decoderFormatRead_ = true;
            }
            if (attr.size > 0) {
                uint8_t *addr = OH_AVBuffer_GetAddr(buffer);
                if (addr == nullptr) {
                    OH_AudioCodec_FreeOutputBuffer(decoder_, index);
                    Fail("无法读取解码后的音频数据");
                    return false;
                }
                if (pcmPtsUs_ < 0) {
                    pcmPtsUs_ = attr.pts >= 0 ? attr.pts : 0;
                }
                AppendPcm(addr + attr.offset, attr.size);
                if (!FeedPcmFrames()) {
                    OH_AudioCodec_FreeOutputBuffer(decoder_, index);
                    return false;
                }
            }
            if ((attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0) {
                decoderEos_ = true;
            }
            OH_AudioCodec_FreeOutputBuffer(decoder_, index);
            if (decoderEos_) {
                return true;
            }
        }
    }

    bool FeedPcmFrames()
    {
        const int32_t frameSamples = spec_.format == AV_OUTPUT_FORMAT_MP3 ? 1152 :
            (spec_.format == AV_OUTPUT_FORMAT_AAC ? 1024 : 4608);
        const int32_t frameBytes = frameSamples * audio_.channels * 2;
        if (frameBytes <= 0 || audio_.sampleRate <= 0) {
            return true;
        }
        while (pcm_.size() - pcmOffset_ >= static_cast<size_t>(frameBytes)) {
            if (!PushToCodec(encoder_, pcm_.data() + pcmOffset_, frameBytes, pcmPtsUs_, 0)) {
                return false;
            }
            pcmOffset_ += frameBytes;
            pcmPtsUs_ += static_cast<int64_t>(frameSamples) * 1000000LL / audio_.sampleRate;
            if (!DrainEncoder()) {
                return false;
            }
        }
        if (pcmOffset_ > 1024 * 1024) {
            pcm_.erase(pcm_.begin(), pcm_.begin() + static_cast<std::ptrdiff_t>(pcmOffset_));
            pcmOffset_ = 0;
        }
        return true;
    }

    bool FlushPcm()
    {
        if (!FeedPcmFrames()) {
            return false;
        }
        if (pcm_.size() > pcmOffset_) {
            size_t remaining = pcm_.size() - pcmOffset_;
            if (!PushToCodec(encoder_, pcm_.data() + pcmOffset_, remaining, pcmPtsUs_, 0)) {
                return false;
            }
            pcmOffset_ = pcm_.size();
        }
        if (!PushToCodec(encoder_, nullptr, 0, pcmPtsUs_, AVCODEC_BUFFER_FLAGS_EOS)) {
            return false;
        }
        for (int32_t i = 0; i < 2000 && !encoderEos_ && !out_.cancelled; ++i) {
            if (!DrainEncoder()) {
                return false;
            }
            if (!encoderEos_) {
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            }
        }
        if (!out_.cancelled && !encoderEos_) {
            return FailBool("编码音频超时，输出可能不完整");
        }
        return true;
    }

    bool EnsureMuxer()
    {
        if (muxerStarted_) {
            return true;
        }
        std::vector<uint8_t> config;
        OH_AVFormat *desc = OH_AudioCodec_GetOutputDescription(encoder_);
        if (desc != nullptr) {
            uint8_t *data = nullptr;
            size_t size = 0;
            if (OH_AVFormat_GetBuffer(desc, OH_MD_KEY_CODEC_CONFIG, &data, &size) && data != nullptr && size > 0) {
                config.assign(data, data + size);
            }
            OH_AVFormat_Destroy(desc);
        }
        OH_AVFormat *trackFormat = OH_AVFormat_CreateAudioFormat(spec_.mime.c_str(), audio_.sampleRate, audio_.channels);
        if (trackFormat == nullptr) {
            return FailBool("无法创建输出音轨");
        }
        if (spec_.format == AV_OUTPUT_FORMAT_FLAC) {
            OH_AVFormat_SetIntValue(trackFormat, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, SAMPLE_S16LE);
        }
        if (spec_.format == AV_OUTPUT_FORMAT_MP3) {
            OH_AVFormat_SetLongValue(trackFormat, OH_MD_KEY_BITRATE, 320000);
        }
        if (spec_.format == AV_OUTPUT_FORMAT_AAC) {
            OH_AVFormat_SetIntValue(trackFormat, OH_MD_KEY_PROFILE, AAC_PROFILE_LC);
            OH_AVFormat_SetIntValue(trackFormat, OH_MD_KEY_AAC_IS_ADTS, 1);
        }
        if (!config.empty() && spec_.format != AV_OUTPUT_FORMAT_AAC) {
            OH_AVFormat_SetBuffer(trackFormat, OH_MD_KEY_CODEC_CONFIG, config.data(), config.size());
        }
        int32_t track = -1;
        OH_AVErrCode addResult = OH_AVMuxer_AddTrack(muxer_, &track, trackFormat);
        OH_AVFormat_Destroy(trackFormat);
        if (addResult != AV_ERR_OK || track < 0) {
            return FailBool(ErrorCodeText("无法写入转码后的音轨", addResult));
        }
        OH_AVErrCode startResult = OH_AVMuxer_Start(muxer_);
        if (startResult != AV_ERR_OK) {
            return FailBool(ErrorCodeText("无法启动输出封装器", startResult));
        }
        muxerStarted_ = true;
        outputTrack_ = track;
        for (const auto &packet : pending_) {
            if (!WritePacket(packet.data.data(), packet.data.size(), packet.pts)) {
                return false;
            }
        }
        pending_.clear();
        return true;
    }

    bool WritePacket(const uint8_t *data, size_t size, int64_t pts)
    {
        if (size == 0) {
            return true;
        }
        if (!muxerStarted_) {
            EncodedPacket packet;
            packet.data.assign(data, data + size);
            packet.pts = pts;
            pending_.push_back(std::move(packet));
            return true;
        }
        if (muxBuffer_ == nullptr || OH_AVBuffer_GetCapacity(muxBuffer_) < static_cast<int32_t>(size)) {
            if (muxBuffer_ != nullptr) {
                OH_AVBuffer_Destroy(muxBuffer_);
            }
            int32_t capacity = std::max(static_cast<int32_t>(size), 1024 * 1024);
            muxBuffer_ = OH_AVBuffer_Create(capacity);
            if (muxBuffer_ == nullptr) {
                return FailBool("内存不足，无法写入编码后的音频");
            }
        }
        uint8_t *addr = OH_AVBuffer_GetAddr(muxBuffer_);
        if (addr == nullptr) {
            return FailBool("无法写入编码后的音频");
        }
        memcpy(addr, data, size);
        if (firstOutputPts_ < 0) {
            firstOutputPts_ = pts;
        }
        int64_t normalized = pts - firstOutputPts_;
        if (normalized < lastOutputPts_) {
            normalized = lastOutputPts_;
        }
        lastOutputPts_ = normalized;
        OH_AVCodecBufferAttr attr {};
        attr.pts = normalized;
        attr.size = static_cast<int32_t>(size);
        attr.offset = 0;
        attr.flags = 0;
        if (OH_AVBuffer_SetBufferAttr(muxBuffer_, &attr) != AV_ERR_OK) {
            return FailBool("无法设置编码后的音频帧");
        }
        OH_AVErrCode result = OH_AVMuxer_WriteSampleBuffer(muxer_, static_cast<uint32_t>(outputTrack_), muxBuffer_);
        if (result != AV_ERR_OK) {
            return FailBool(ErrorCodeText("写入编码后的音频失败", result));
        }
        out_.bytes += static_cast<int64_t>(size);
        return true;
    }

    bool DrainEncoder()
    {
        while (true) {
            uint32_t index = 0;
            OH_AVErrCode result = OH_AudioCodec_QueryOutputBuffer(encoder_, &index, 0);
            if (IsRetry(result)) {
                return true;
            }
            if (result != AV_ERR_OK) {
                return FailBool(ErrorCodeText("读取编码后的音频失败", result));
            }
            OH_AVBuffer *buffer = OH_AudioCodec_GetOutputBuffer(encoder_, index);
            if (buffer == nullptr) {
                return FailBool("无法获取编码后的音频缓冲区");
            }
            OH_AVCodecBufferAttr attr {};
            if (OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK) {
                OH_AudioCodec_FreeOutputBuffer(encoder_, index);
                return FailBool("无法读取编码帧信息");
            }
            bool codecData = (attr.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA) != 0;
            if (!muxerStarted_ && (attr.size > 0 || codecData)) {
                if (!EnsureMuxer()) {
                    OH_AudioCodec_FreeOutputBuffer(encoder_, index);
                    return false;
                }
            }
            if (attr.size > 0 && !codecData && muxerStarted_) {
                uint8_t *addr = OH_AVBuffer_GetAddr(buffer);
                if (addr == nullptr) {
                    OH_AudioCodec_FreeOutputBuffer(encoder_, index);
                    return FailBool("无法读取编码后的音频数据");
                }
                if (!WritePacket(addr + attr.offset, static_cast<size_t>(attr.size), attr.pts)) {
                    OH_AudioCodec_FreeOutputBuffer(encoder_, index);
                    return false;
                }
            }
            if ((attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0) {
                encoderEos_ = true;
            }
            OH_AudioCodec_FreeOutputBuffer(encoder_, index);
            if (encoderEos_) {
                return true;
            }
        }
    }

    ExtractParams params_;
    AudioInfo audio_;
    OutputSpec spec_;
    int64_t durationUs_ = 0;
    ExtractOutcome out_;
    OH_AVSource *source_ = nullptr;
    OH_AVDemuxer *demuxer_ = nullptr;
    OH_AVMuxer *muxer_ = nullptr;
    bool muxerStarted_ = false;
    int32_t outputTrack_ = -1;
    OH_AVBuffer *inputBuffer_ = nullptr;
    OH_AVBuffer *muxBuffer_ = nullptr;
    OH_AVCodec *decoder_ = nullptr;
    OH_AVCodec *encoder_ = nullptr;
    bool decoderStarted_ = false;
    bool encoderStarted_ = false;
    bool decoderEos_ = false;
    bool encoderEos_ = false;
    bool decoderFormatRead_ = false;
    int32_t pcmFormat_ = SAMPLE_S16LE;
    int64_t pcmPtsUs_ = -1;
    int64_t firstOutputPts_ = -1;
    int64_t lastOutputPts_ = 0;
    std::vector<uint8_t> pcm_;
    size_t pcmOffset_ = 0;
    std::vector<EncodedPacket> pending_;
};

/**
 * Decodes the first audio track to 16-bit PCM and writes a RIFF/WAVE or AIFF
 * file. Both containers use streaming writes and O(1) memory. The header is
 * reserved up front and patched once the final byte count is known.
 */
class PcmExporter {
public:
    PcmExporter(const ExtractParams &params, const AudioInfo &audio, const OutputSpec &spec,
        int64_t durationUs)
        : params_(params), audio_(audio), spec_(spec), durationUs_(durationUs) {}

    ~PcmExporter()
    {
        if (decoder_ != nullptr) {
            if (decoderStarted_) {
                OH_AudioCodec_Stop(decoder_);
            }
            OH_AudioCodec_Destroy(decoder_);
        }
        if (inputBuffer_ != nullptr) {
            OH_AVBuffer_Destroy(inputBuffer_);
        }
        if (demuxer_ != nullptr) {
            OH_AVDemuxer_Destroy(demuxer_);
        }
        if (source_ != nullptr) {
            OH_AVSource_Destroy(source_);
        }
    }

    ExtractOutcome Run()
    {
        out_.format = params_.format;
        out_.durationUs = durationUs_;
        auto started = std::chrono::steady_clock::now();
        if (ftruncate(params_.outputFd, 0) != 0 || lseek(params_.outputFd, 0, SEEK_SET) < 0) {
            return Fail("无法写入保存位置，请重新选择一个文件夹");
        }
        source_ = OH_AVSource_CreateWithFD(params_.inputFd, 0, params_.inputSize);
        if (source_ == nullptr) {
            return Fail("无法解析这个文件，可能是格式不受支持或文件已损坏");
        }
        demuxer_ = OH_AVDemuxer_CreateWithSource(source_);
        if (demuxer_ == nullptr) {
            return Fail("无法创建音频解复用器");
        }
        if (OH_AVDemuxer_SelectTrackByID(demuxer_, audio_.trackIndex) != AV_ERR_OK) {
            return Fail("无法选择音频轨道");
        }
        if (!CreateDecoder()) {
            return out_;
        }
        if (!ReserveHeader()) {
            return out_;
        }
        ResetProgress(durationUs_);

        int32_t capacity = audio_.maxInputSize > 0 ? audio_.maxInputSize : kDefaultSampleBuffer;
        capacity = std::max(kMinSampleBuffer, std::min(kMaxSampleBuffer, capacity));
        inputBuffer_ = OH_AVBuffer_Create(capacity);
        if (inputBuffer_ == nullptr) {
            return Fail("内存不足，无法创建音频缓冲区");
        }

        int64_t lastInputPts = 0;
        bool inputEos = false;
        while (!inputEos) {
            if (IsCancelled()) {
                out_.cancelled = true;
                break;
            }
            OH_AVErrCode readResult = OH_AVDemuxer_ReadSampleBuffer(demuxer_, audio_.trackIndex, inputBuffer_);
            if (readResult != AV_ERR_OK) {
                return Fail(ErrorCodeText("读取音频数据失败", readResult));
            }
            OH_AVCodecBufferAttr attr {};
            OH_AVErrCode attrResult = OH_AVBuffer_GetBufferAttr(inputBuffer_, &attr);
            if (attrResult != AV_ERR_OK) {
                return Fail(ErrorCodeText("读取音频帧信息失败", attrResult));
            }
            if (attr.size > 0) {
                uint8_t *data = OH_AVBuffer_GetAddr(inputBuffer_);
                if (data == nullptr) {
                    return Fail("无法读取音频帧");
                }
                int64_t pts = attr.pts >= 0 ? attr.pts : lastInputPts;
                if (!PushInput(data + attr.offset, static_cast<size_t>(attr.size), pts, 0)) {
                    return out_;
                }
                lastInputPts = pts;
                lastPts_ = pts;
                UpdateProgress(pts, out_.bytes);
            }
            if ((attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0) {
                if (!PushInput(nullptr, 0, lastInputPts, AVCODEC_BUFFER_FLAGS_EOS)) {
                    return out_;
                }
                inputEos = true;
            }
            if (!DrainDecoder()) {
                return out_;
            }
            if (out_.cancelled) {
                break;
            }
        }

        for (int32_t i = 0; i < 2000 && !out_.cancelled && !decoderEos_; ++i) {
            if (!DrainDecoder()) {
                return out_;
            }
            if (!decoderEos_) {
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            }
        }
        if (!out_.cancelled && !decoderEos_) {
            return Fail("解码音频超时，文件可能已损坏");
        }
        if (!out_.cancelled) {
            if (dataBytes_ <= 0) {
                return Fail("没有读到音频数据，文件可能没有可转换的声音");
            }
            if (dataBytes_ > 0xFFFFFFFFLL - 64) {
                return Fail("WAV/AIFF 不支持超过 4GB 的音频，请改用 FLAC 或 MP3");
            }
            if (!WriteHeader()) {
                return out_;
            }
            if (fsync(params_.outputFd) != 0) {
                OH_LOG_WARN(LOG_APP, "fsync pcm output failed: %{public}d", errno);
            }
            out_.ok = true;
        }
        out_.elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - started).count();
        if (out_.cancelled) {
            FinishProgress("cancelled", "", lastPts_, out_.bytes);
        } else if (out_.ok) {
            FinishProgress("done", "", durationUs_, out_.bytes);
        } else {
            FinishProgress("error", out_.error, lastPts_, out_.bytes);
        }
        return out_;
    }

private:
    ExtractOutcome Fail(const std::string &error)
    {
        out_.error = error;
        FinishProgress("error", error, lastPts_, out_.bytes);
        return out_;
    }

    bool FailBool(const std::string &error)
    {
        Fail(error);
        return false;
    }

    bool CreateDecoder()
    {
        OH_AVFormat *format = OH_AVFormat_CreateAudioFormat(audio_.mime.c_str(), audio_.sampleRate, audio_.channels);
        if (format == nullptr) {
            return FailBool("无法创建音频解码配置");
        }
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUD_SAMPLE_RATE, audio_.sampleRate);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUD_CHANNEL_COUNT, audio_.channels);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, SAMPLE_S16LE);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_ENABLE_SYNC_MODE, 1);
        if (audio_.hasConfig) {
            OH_AVFormat_SetBuffer(format, OH_MD_KEY_CODEC_CONFIG, audio_.codecConfig.data(), audio_.codecConfig.size());
        }
        if (audio_.adts != 0) {
            OH_AVFormat_SetIntValue(format, OH_MD_KEY_AAC_IS_ADTS, 1);
        }
        decoder_ = OH_AudioCodec_CreateByMime(audio_.mime.c_str(), false);
        if (decoder_ == nullptr) {
            OH_AVFormat_Destroy(format);
            return FailBool("当前音轨的解码器不可用");
        }
        OH_AVErrCode result = OH_AudioCodec_Configure(decoder_, format);
        OH_AVFormat_Destroy(format);
        if (result != AV_ERR_OK) {
            return FailBool(ErrorCodeText("无法配置音频解码器", result));
        }
        result = OH_AudioCodec_Prepare(decoder_);
        if (result != AV_ERR_OK) {
            return FailBool(ErrorCodeText("无法准备音频解码器", result));
        }
        result = OH_AudioCodec_Start(decoder_);
        if (result != AV_ERR_OK) {
            return FailBool(ErrorCodeText("无法启动音频解码器", result));
        }
        decoderStarted_ = true;
        return true;
    }

    bool PushInput(const uint8_t *data, size_t size, int64_t pts, uint32_t flags)
    {
        uint32_t index = 0;
        OH_AVErrCode query = AV_ERR_TRY_AGAIN_LATER;
        for (int32_t i = 0; i < 200; ++i) {
            query = OH_AudioCodec_QueryInputBuffer(decoder_, &index, 10000);
            if (query == AV_ERR_OK) {
                break;
            }
            if (query != AV_ERR_TRY_AGAIN_LATER) {
                return FailBool(ErrorCodeText("等待音频输入缓冲区失败", query));
            }
        }
        if (query != AV_ERR_OK) {
            return FailBool("等待音频输入缓冲区超时");
        }
        OH_AVBuffer *buffer = OH_AudioCodec_GetInputBuffer(decoder_, index);
        if (buffer == nullptr) {
            return FailBool("无法获取音频输入缓冲区");
        }
        if (size > 0 && data != nullptr) {
            uint8_t *addr = OH_AVBuffer_GetAddr(buffer);
            int32_t capacity = OH_AVBuffer_GetCapacity(buffer);
            if (addr == nullptr || capacity < static_cast<int32_t>(size)) {
                return FailBool("音频帧大于输入缓冲区");
            }
            memcpy(addr, data, size);
        }
        OH_AVCodecBufferAttr attr {};
        attr.pts = pts;
        attr.size = static_cast<int32_t>(size);
        attr.offset = 0;
        attr.flags = flags;
        if (OH_AVBuffer_SetBufferAttr(buffer, &attr) != AV_ERR_OK) {
            return FailBool("无法设置音频输入帧");
        }
        OH_AVErrCode result = OH_AudioCodec_PushInputBuffer(decoder_, index);
        if (result != AV_ERR_OK) {
            return FailBool(ErrorCodeText("无法送入音频输入帧", result));
        }
        return true;
    }

    bool DrainDecoder()
    {
        while (true) {
            uint32_t index = 0;
            OH_AVErrCode result = OH_AudioCodec_QueryOutputBuffer(decoder_, &index, 0);
            if (result == AV_ERR_TRY_AGAIN_LATER) {
                return true;
            }
            if (result != AV_ERR_OK) {
                return FailBool(ErrorCodeText("读取解码后的音频失败", result));
            }
            OH_AVBuffer *buffer = OH_AudioCodec_GetOutputBuffer(decoder_, index);
            if (buffer == nullptr) {
                return FailBool("无法获取解码后的音频缓冲区");
            }
            OH_AVCodecBufferAttr attr {};
            if (OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK) {
                OH_AudioCodec_FreeOutputBuffer(decoder_, index);
                return FailBool("无法读取解码帧信息");
            }
            if (attr.size > 0) {
                if (!decoderFormatRead_) {
                    OH_AVFormat *desc = OH_AudioCodec_GetOutputDescription(decoder_);
                    if (desc != nullptr) {
                        OH_AVFormat_GetIntValue(desc, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, &pcmFormat_);
                        OH_AVFormat_Destroy(desc);
                    }
                    decoderFormatRead_ = true;
                }
                uint8_t *addr = OH_AVBuffer_GetAddr(buffer);
                if (addr == nullptr || !AppendPcm(addr + attr.offset, static_cast<size_t>(attr.size))) {
                    OH_AudioCodec_FreeOutputBuffer(decoder_, index);
                    return false;
                }
                if (attr.pts >= 0) {
                    lastPts_ = attr.pts;
                }
                UpdateProgress(lastPts_, out_.bytes);
            }
            if ((attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0) {
                decoderEos_ = true;
            }
            OH_AudioCodec_FreeOutputBuffer(decoder_, index);
            if (decoderEos_) {
                return true;
            }
        }
    }

    bool AppendPcm(const uint8_t *data, size_t size)
    {
        if (data == nullptr || size == 0) {
            return true;
        }
        if (pcmFormat_ == SAMPLE_S16LE) {
            return WritePcm(data, size);
        }
        if (pcmFormat_ == SAMPLE_F32LE) {
            size_t count = size / 4;
            std::vector<uint8_t> converted(count * 2);
            for (size_t i = 0; i < count; ++i) {
                float sample = 0.0f;
                memcpy(&sample, data + i * 4, sizeof(float));
                float clamped = std::max(-1.0f, std::min(1.0f, sample));
                int16_t value = static_cast<int16_t>(clamped * 32767.0f);
                converted[i * 2] = static_cast<uint8_t>(value & 0xFF);
                converted[i * 2 + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
            }
            return WritePcm(converted.data(), converted.size());
        }
        if (pcmFormat_ == SAMPLE_S32LE) {
            size_t count = size / 4;
            std::vector<uint8_t> converted(count * 2);
            for (size_t i = 0; i < count; ++i) {
                int32_t sample = 0;
                memcpy(&sample, data + i * 4, sizeof(int32_t));
                int16_t value = static_cast<int16_t>(sample >> 16);
                converted[i * 2] = static_cast<uint8_t>(value & 0xFF);
                converted[i * 2 + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
            }
            return WritePcm(converted.data(), converted.size());
        }
        if (pcmFormat_ == SAMPLE_S24LE) {
            size_t count = size / 3;
            std::vector<uint8_t> converted(count * 2);
            for (size_t i = 0; i < count; ++i) {
                int32_t sample = static_cast<int32_t>(data[i * 3]) |
                    (static_cast<int32_t>(data[i * 3 + 1]) << 8) |
                    (static_cast<int32_t>(data[i * 3 + 2]) << 16);
                if ((sample & 0x800000) != 0) {
                    sample |= ~0xFFFFFF;
                }
                int16_t value = static_cast<int16_t>(sample >> 8);
                converted[i * 2] = static_cast<uint8_t>(value & 0xFF);
                converted[i * 2 + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
            }
            return WritePcm(converted.data(), converted.size());
        }
        if (pcmFormat_ == SAMPLE_U8) {
            std::vector<uint8_t> converted(size * 2);
            for (size_t i = 0; i < size; ++i) {
                int16_t value = (static_cast<int16_t>(data[i]) - 128) << 8;
                converted[i * 2] = static_cast<uint8_t>(value & 0xFF);
                converted[i * 2 + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
            }
            return WritePcm(converted.data(), converted.size());
        }
        return FailBool("解码器输出的 PCM 格式暂不支持");
    }

    bool WritePcm(const uint8_t *data, size_t size)
    {
        if (spec_.pcm == PcmKind::Aiff) {
            std::vector<uint8_t> swapped(size);
            for (size_t i = 0; i + 1 < size; i += 2) {
                swapped[i] = data[i + 1];
                swapped[i + 1] = data[i];
            }
            return WriteAll(swapped.data(), swapped.size());
        }
        return WriteAll(data, size);
    }

    bool WriteAll(const uint8_t *data, size_t size)
    {
        size_t written = 0;
        while (written < size) {
            ssize_t count = write(params_.outputFd, data + written, size - written);
            if (count <= 0) {
                if (errno == EINTR) {
                    continue;
                }
                return FailBool("写入音频文件失败，请确认保存位置有足够空间");
            }
            written += static_cast<size_t>(count);
        }
        dataBytes_ += static_cast<int64_t>(size);
        out_.bytes = dataBytes_;
        return true;
    }

    bool ReserveHeader()
    {
        headerSize_ = spec_.pcm == PcmKind::Aiff ? 54 : 44;
        if (!WriteHeader()) {
            return false;
        }
        return lseek(params_.outputFd, headerSize_, SEEK_SET) == headerSize_;
    }

    bool WriteHeader()
    {
        std::vector<uint8_t> header(headerSize_, 0);
        if (spec_.pcm == PcmKind::Aiff) {
            PutTag(header, 0, "FORM");
            PutU32BE(header, 4, static_cast<uint32_t>(46 + dataBytes_));
            PutTag(header, 8, "AIFF");
            PutTag(header, 12, "COMM");
            PutU32BE(header, 16, 18);
            PutU16BE(header, 20, static_cast<uint16_t>(audio_.channels));
            uint32_t frames = audio_.sampleRate > 0 ?
                static_cast<uint32_t>(dataBytes_ / (audio_.channels * 2)) : 0;
            PutU32BE(header, 22, frames);
            PutU16BE(header, 26, 16);
            WriteRate80(&header[28], audio_.sampleRate);
            PutTag(header, 38, "SSND");
            PutU32BE(header, 42, static_cast<uint32_t>(dataBytes_ + 8));
            PutU32BE(header, 46, 0);
            PutU32BE(header, 50, 0);
        } else {
            PutTag(header, 0, "RIFF");
            PutU32LE(header, 4, static_cast<uint32_t>(36 + dataBytes_));
            PutTag(header, 8, "WAVE");
            PutTag(header, 12, "fmt ");
            PutU32LE(header, 16, 16);
            PutU16LE(header, 20, 1);
            PutU16LE(header, 22, static_cast<uint16_t>(audio_.channels));
            PutU32LE(header, 24, static_cast<uint32_t>(std::max(0, audio_.sampleRate)));
            uint32_t blockAlign = static_cast<uint32_t>(std::max(1, audio_.channels) * 2);
            PutU32LE(header, 28, static_cast<uint32_t>(std::max(0, audio_.sampleRate)) * blockAlign);
            PutU16LE(header, 32, static_cast<uint16_t>(blockAlign));
            PutU16LE(header, 34, 16);
            PutTag(header, 36, "data");
            PutU32LE(header, 40, static_cast<uint32_t>(dataBytes_));
        }
        ssize_t result = pwrite(params_.outputFd, header.data(), header.size(), 0);
        if (result != static_cast<ssize_t>(header.size())) {
            return FailBool("无法写入音频文件头");
        }
        return true;
    }

    static void PutTag(std::vector<uint8_t> &out, size_t at, const char *tag)
    {
        memcpy(out.data() + at, tag, 4);
    }

    static void PutU16LE(std::vector<uint8_t> &out, size_t at, uint16_t value)
    {
        out[at] = static_cast<uint8_t>(value & 0xFF);
        out[at + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
    }

    static void PutU32LE(std::vector<uint8_t> &out, size_t at, uint32_t value)
    {
        for (int i = 0; i < 4; ++i) {
            out[at + i] = static_cast<uint8_t>((value >> (8 * i)) & 0xFF);
        }
    }

    static void PutU16BE(std::vector<uint8_t> &out, size_t at, uint16_t value)
    {
        out[at] = static_cast<uint8_t>((value >> 8) & 0xFF);
        out[at + 1] = static_cast<uint8_t>(value & 0xFF);
    }

    static void PutU32BE(std::vector<uint8_t> &out, size_t at, uint32_t value)
    {
        for (int i = 0; i < 4; ++i) {
            out[at + i] = static_cast<uint8_t>((value >> (24 - 8 * i)) & 0xFF);
        }
    }

    static void WriteRate80(uint8_t *out, int32_t rate)
    {
        int32_t exp = 0;
        long double value = rate > 0 ? static_cast<long double>(rate) : 44100.0L;
        while (value >= 2.0L) {
            value /= 2.0L;
            ++exp;
        }
        uint16_t exponent = static_cast<uint16_t>(16383 + exp);
        unsigned long long mantissa = static_cast<unsigned long long>(
            value * 9223372036854775808.0L);
        out[0] = static_cast<uint8_t>((exponent >> 8) & 0xFF);
        out[1] = static_cast<uint8_t>(exponent & 0xFF);
        for (int i = 0; i < 8; ++i) {
            out[2 + i] = static_cast<uint8_t>((mantissa >> (56 - 8 * i)) & 0xFF);
        }
    }

    ExtractParams params_;
    AudioInfo audio_;
    OutputSpec spec_;
    int64_t durationUs_ = 0;
    ExtractOutcome out_;
    OH_AVSource *source_ = nullptr;
    OH_AVDemuxer *demuxer_ = nullptr;
    OH_AVCodec *decoder_ = nullptr;
    OH_AVBuffer *inputBuffer_ = nullptr;
    bool decoderStarted_ = false;
    bool decoderEos_ = false;
    bool decoderFormatRead_ = false;
    int32_t pcmFormat_ = SAMPLE_S16LE;
    int64_t dataBytes_ = 0;
    int64_t lastPts_ = 0;
    size_t headerSize_ = 44;
};

ExtractOutcome RunExtract(const ExtractParams &params)
{
    ExtractOutcome out;
    out.format = params.format;
    auto started = std::chrono::steady_clock::now();

    struct stat statBuf {};
    int64_t inputSize = params.inputSize;
    if (inputSize <= 0 && fstat(params.inputFd, &statBuf) == 0) {
        inputSize = static_cast<int64_t>(statBuf.st_size);
    }
    if (inputSize <= 0) {
        out.error = "无法读取视频文件大小";
        FinishProgress("error", out.error, 0, 0);
        return out;
    }

    if (ftruncate(params.outputFd, 0) != 0 || lseek(params.outputFd, 0, SEEK_SET) < 0) {
        out.error = "无法写入保存位置，请重新选择一个文件夹";
        FinishProgress("error", out.error, 0, 0);
        return out;
    }

    MediaGuard media;
    media.source = OH_AVSource_CreateWithFD(params.inputFd, 0, inputSize);
    if (media.source == nullptr) {
        out.error = "无法解析这个视频，可能是格式不受支持或文件已损坏";
        FinishProgress("error", out.error, 0, 0);
        return out;
    }

    int32_t trackCount = 0;
    int64_t durationUs = 0;
    OH_AVFormat *sourceFormat = OH_AVSource_GetSourceFormat(media.source);
    if (sourceFormat == nullptr) {
        out.error = "无法读取视频的媒体信息";
        FinishProgress("error", out.error, 0, 0);
        return out;
    }
    OH_AVFormat_GetIntValue(sourceFormat, OH_MD_KEY_TRACK_COUNT, &trackCount);
    OH_AVFormat_GetLongValue(sourceFormat, OH_MD_KEY_DURATION, &durationUs);
    OH_AVFormat_Destroy(sourceFormat);
    out.durationUs = durationUs;

    AudioInfo audio;
    for (int32_t i = 0; i < trackCount; ++i) {
        OH_AVFormat *trackFormat = OH_AVSource_GetTrackFormat(media.source, static_cast<uint32_t>(i));
        if (trackFormat == nullptr) {
            continue;
        }
        int32_t trackType = -1;
        OH_AVFormat_GetIntValue(trackFormat, OH_MD_KEY_TRACK_TYPE, &trackType);
        if (trackType == MEDIA_TYPE_AUD && !audio.present) {
            if (ReadAudioInfo(trackFormat, &audio)) {
                audio.trackIndex = static_cast<uint32_t>(i);
            }
        }
        OH_AVFormat_Destroy(trackFormat);
    }
    if (!audio.present) {
        out.error = "这个文件没有音频轨道";
        FinishProgress("error", out.error, 0, 0);
        return out;
    }

    OutputSpec spec;
    std::string resolveError;
    if (!ResolveOutput(params.format, audio, &spec, &resolveError)) {
        out.error = resolveError;
        FinishProgress("error", out.error, 0, 0);
        return out;
    }
    out.format = params.format.empty() || params.format == "auto" ? audio.suggestedFormat : params.format;

    if (spec.direct && (spec.format == AV_OUTPUT_FORMAT_FLAC || spec.format == AV_OUTPUT_FORMAT_OGG) &&
        !audio.hasConfig) {
        out.error = "音轨缺少编解码配置，无法无损封装为 " + out.format;
        FinishProgress("error", out.error, 0, 0);
        return out;
    }

    if (spec.pcm != PcmKind::None) {
        PcmExporter exporter(params, audio, spec, durationUs);
        return exporter.Run();
    }

    if (spec.transcode) {
        Transcoder transcoder(params, audio, spec, durationUs);
        return transcoder.Run();
    }

    ResetProgress(durationUs);

    media.demuxer = OH_AVDemuxer_CreateWithSource(media.source);
    if (media.demuxer == nullptr) {
        out.error = "无法创建音频解复用器";
        FinishProgress("error", out.error, 0, 0);
        return out;
    }

    media.muxer = OH_AVMuxer_Create(params.outputFd, spec.format);
    if (media.muxer == nullptr) {
        out.error = "无法创建输出文件，可能是保存位置不可写或格式不受支持";
        FinishProgress("error", out.error, 0, 0);
        return out;
    }

    OH_AVFormat *trackFormat = OH_AVFormat_CreateAudioFormat(spec.mime.c_str(), audio.sampleRate, audio.channels);
    if (trackFormat == nullptr) {
        out.error = "无法创建输出音轨";
        FinishProgress("error", out.error, 0, 0);
        return out;
    }
    if (spec.format == AV_OUTPUT_FORMAT_FLAC) {
        // FLAC muxing requires the PCM sample format even when compressed
        // packets are copied. Without this key AddTrack returns AV_ERR_INVALID_VAL.
        int32_t sampleFormat = audio.sampleFormat > 0 ? audio.sampleFormat : SAMPLE_S16LE;
        OH_AVFormat_SetIntValue(trackFormat, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, sampleFormat);
    }
    if (spec.aac && spec.adts) {
        OH_AVFormat_SetIntValue(trackFormat, OH_MD_KEY_AAC_IS_ADTS, 1);
        int32_t profile = audio.profile >= 0 ? audio.profile : AAC_PROFILE_LC;
        OH_AVFormat_SetIntValue(trackFormat, OH_MD_KEY_PROFILE, profile);
    }

    std::vector<uint8_t> config = audio.codecConfig;
    if (spec.aac && !spec.adts && config.empty()) {
        config = MakeAacConfig(audio);
    }
    if (!config.empty() && !spec.adts) {
        OH_AVFormat_SetBuffer(trackFormat, OH_MD_KEY_CODEC_CONFIG, config.data(), config.size());
    } else if (spec.aac && !spec.adts) {
        OH_AVFormat_Destroy(trackFormat);
        out.error = "AAC 音轨缺少编码配置，无法封装为 M4A";
        FinishProgress("error", out.error, 0, 0);
        return out;
    }

    int32_t outputTrackIndex = -1;
    OH_AVErrCode addResult = OH_AVMuxer_AddTrack(media.muxer, &outputTrackIndex, trackFormat);
    OH_AVFormat_Destroy(trackFormat);
    if (addResult != AV_ERR_OK || outputTrackIndex < 0) {
        out.error = ErrorCodeText("无法把音轨写入输出文件", addResult);
        FinishProgress("error", out.error, 0, 0);
        return out;
    }

    OH_AVErrCode startResult = OH_AVMuxer_Start(media.muxer);
    if (startResult != AV_ERR_OK) {
        out.error = ErrorCodeText("无法启动输出封装器", startResult);
        FinishProgress("error", out.error, 0, 0);
        return out;
    }
    media.muxerStarted = true;

    int32_t capacity = audio.maxInputSize > 0 ? audio.maxInputSize : kDefaultSampleBuffer;
    capacity = std::max(kMinSampleBuffer, std::min(kMaxSampleBuffer, capacity));
    media.buffer = OH_AVBuffer_Create(capacity);
    if (media.buffer == nullptr) {
        out.error = "内存不足，无法创建音频缓冲区";
        FinishProgress("error", out.error, 0, 0);
        return out;
    }

    OH_AVErrCode selectResult = OH_AVDemuxer_SelectTrackByID(media.demuxer, audio.trackIndex);
    if (selectResult != AV_ERR_OK) {
        out.error = ErrorCodeText("无法选择音频轨道", selectResult);
        FinishProgress("error", out.error, 0, 0);
        return out;
    }

    int64_t firstPts = -1;
    int64_t lastPts = 0;
    int64_t bytes = 0;
    bool eos = false;
    while (!eos) {
        if (IsCancelled()) {
            out.cancelled = true;
            break;
        }
        OH_AVErrCode readResult = OH_AVDemuxer_ReadSampleBuffer(media.demuxer, audio.trackIndex, media.buffer);
        if (readResult != AV_ERR_OK) {
            out.error = ErrorCodeText("读取音频数据失败", readResult);
            break;
        }
        OH_AVCodecBufferAttr attr {};
        OH_AVErrCode attrResult = OH_AVBuffer_GetBufferAttr(media.buffer, &attr);
        if (attrResult != AV_ERR_OK) {
            out.error = ErrorCodeText("读取音频帧信息失败", attrResult);
            break;
        }
        eos = (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0;
        if (attr.size > 0) {
            if (firstPts < 0) {
                firstPts = attr.pts >= 0 ? attr.pts : 0;
            }
            if (attr.pts < 0) {
                attr.pts = lastPts;
            } else {
                attr.pts -= firstPts;
            }
            if (attr.pts < lastPts) {
                attr.pts = lastPts;
            }
            OH_AVErrCode setAttrResult = OH_AVBuffer_SetBufferAttr(media.buffer, &attr);
            if (setAttrResult != AV_ERR_OK) {
                out.error = ErrorCodeText("准备音频帧失败", setAttrResult);
                break;
            }
            OH_AVErrCode writeResult = OH_AVMuxer_WriteSampleBuffer(media.muxer, outputTrackIndex, media.buffer);
            if (writeResult != AV_ERR_OK) {
                out.error = ErrorCodeText("写入音频数据失败", writeResult);
                break;
            }
            bytes += attr.size;
            lastPts = attr.pts;
            UpdateProgress(lastPts, bytes);
        }
    }

    if (out.error.empty() && !out.cancelled && bytes <= 0) {
        out.error = "没有读到音频数据，视频可能没有可提取的声音";
    }

    if (out.error.empty() && media.muxerStarted) {
        OH_AVErrCode stopResult = OH_AVMuxer_Stop(media.muxer);
        media.muxerStarted = false;
        if (stopResult != AV_ERR_OK) {
            out.error = ErrorCodeText("完成封装失败", stopResult);
        }
    }
    if (out.error.empty() && !out.cancelled) {
        // fsync is best-effort: some document providers reject it, but the muxer
        // has already flushed the container through OH_AVMuxer_Stop.
        if (fsync(params.outputFd) != 0) {
            OH_LOG_WARN(LOG_APP, "fsync output failed: %{public}d", errno);
        }
        out.ok = true;
    }

    out.bytes = bytes;
    if (out.durationUs <= 0) {
        out.durationUs = lastPts;
    }
    out.elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - started).count();

    if (out.ok) {
        FinishProgress("done", "", out.durationUs, bytes);
    } else if (out.cancelled) {
        FinishProgress("cancelled", "", lastPts, bytes);
    } else {
        FinishProgress("error", out.error, lastPts, bytes);
    }
    return out;
}

struct AsyncContext {
    napi_env env = nullptr;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    ExtractParams params;
    ExtractOutcome outcome;
};

void ExecuteExtract(napi_env env, void *data)
{
    auto *context = static_cast<AsyncContext *>(data);
    if (context == nullptr) {
        return;
    }
    context->outcome = RunExtract(context->params);
}

std::string OutcomeJson(const ExtractOutcome &outcome)
{
    std::ostringstream out;
    out << "{\"ok\":" << (outcome.ok ? "true" : "false")
        << ",\"cancelled\":" << (outcome.cancelled ? "true" : "false")
        << ",\"error\":" << Quote(outcome.error)
        << ",\"format\":" << Quote(outcome.format)
        << ",\"bytes\":" << outcome.bytes
        << ",\"durationUs\":" << outcome.durationUs
        << ",\"elapsedMs\":" << outcome.elapsedMs << "}";
    return out.str();
}

napi_value MakeExtractError(napi_env env, const std::string &message)
{
    napi_value code = nullptr;
    napi_value messageValue = nullptr;
    napi_value errorValue = nullptr;
    napi_create_string_utf8(env, "ERR_EXTRACT", NAPI_AUTO_LENGTH, &code);
    napi_create_string_utf8(env, message.c_str(), NAPI_AUTO_LENGTH, &messageValue);
    napi_create_error(env, code, messageValue, &errorValue);
    return errorValue;
}

void CompleteExtract(napi_env env, napi_status status, void *data)
{
    auto *context = static_cast<AsyncContext *>(data);
    if (context == nullptr) {
        return;
    }
    g_busy.store(false);
    std::string json = OutcomeJson(context->outcome);
    napi_value result = nullptr;
    napi_create_string_utf8(env, json.c_str(), NAPI_AUTO_LENGTH, &result);

    if (context->outcome.ok || context->outcome.cancelled) {
        napi_resolve_deferred(env, context->deferred, result);
    } else {
        std::string message = context->outcome.error.empty() ? "提取失败" : context->outcome.error;
        napi_reject_deferred(env, context->deferred, MakeExtractError(env, message));
    }

    napi_delete_async_work(env, context->work);
    delete context;
}

napi_value ThrowTypeError(napi_env env, const char *message)
{
    napi_throw_type_error(env, nullptr, message);
    return nullptr;
}

napi_value Probe(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return ThrowTypeError(env, "probe 需要文件描述符");
    }
    int32_t fd = -1;
    int64_t size = 0;
    if (napi_get_value_int32(env, args[0], &fd) != napi_ok) {
        return ThrowTypeError(env, "文件描述符必须是整数");
    }
    if (argc >= 2) {
        napi_get_value_int64(env, args[1], &size);
    }
    std::string json = ProbeFd(fd, size);
    napi_value result = nullptr;
    napi_create_string_utf8(env, json.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value GetProgress(napi_env env, napi_callback_info info)
{
    (void)info;
    std::string json = ProgressJson();
    napi_value result = nullptr;
    napi_create_string_utf8(env, json.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value Cancel(napi_env env, napi_callback_info info)
{
    (void)info;
    {
        std::lock_guard<std::mutex> lock(g_progress.mutex);
        if (g_progress.running) {
            g_progress.cancel = true;
        }
    }
    return nullptr;
}

napi_value Version(napi_env env, napi_callback_info info)
{
    (void)info;
    napi_value result = nullptr;
    napi_create_string_utf8(env, "1.0.0", NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value Extract(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4) {
        return ThrowTypeError(env, "extract 需要输入FD、文件大小、输出FD和格式");
    }

    ExtractParams params;
    if (napi_get_value_int32(env, args[0], &params.inputFd) != napi_ok ||
        napi_get_value_int64(env, args[1], &params.inputSize) != napi_ok ||
        napi_get_value_int32(env, args[2], &params.outputFd) != napi_ok) {
        return ThrowTypeError(env, "文件描述符或文件大小参数无效");
    }
    char format[32] = {0};
    size_t formatLength = 0;
    if (napi_get_value_string_utf8(env, args[3], format, sizeof(format), &formatLength) != napi_ok) {
        return ThrowTypeError(env, "输出格式参数无效");
    }
    params.format = format;
    if (params.inputFd < 0 || params.outputFd < 0) {
        return ThrowTypeError(env, "文件描述符不能为负数");
    }

    if (g_busy.exchange(true)) {
        napi_throw_error(env, nullptr, "已有提取任务正在进行");
        return nullptr;
    }

    ResetProgress(0);
    napi_deferred deferred = nullptr;
    napi_value promise = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        g_busy.store(false);
        FinishProgress("error", "无法创建异步任务", 0, 0);
        return ThrowTypeError(env, "无法创建异步任务");
    }

    auto *context = new AsyncContext();
    context->env = env;
    context->deferred = deferred;
    context->params = params;
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "ruinsss_extract", NAPI_AUTO_LENGTH, &resourceName);
    napi_status workStatus = napi_create_async_work(
        env, nullptr, resourceName, ExecuteExtract, CompleteExtract, context, &context->work);
    if (workStatus != napi_ok) {
        g_busy.store(false);
        FinishProgress("error", "无法创建提取任务", 0, 0);
        delete context;
        napi_reject_deferred(env, deferred, MakeExtractError(env, "无法创建提取任务"));
        return promise;
    }
    napi_queue_async_work(env, context->work);
    return promise;
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        {"probe", nullptr, Probe, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"extract", nullptr, Extract, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getProgress", nullptr, GetProgress, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancel", nullptr, Cancel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"version", nullptr, Version, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
    return exports;
}

napi_module g_module = {};

} // namespace

extern "C" __attribute__((constructor)) void RegisterRuinsssMediaModule(void)
{
    g_module.nm_version = 1;
    g_module.nm_flags = 0;
    g_module.nm_filename = nullptr;
    g_module.nm_register_func = Init;
    g_module.nm_modname = "ruinsss_media";
    g_module.nm_priv = nullptr;
    napi_module_register(&g_module);
}
