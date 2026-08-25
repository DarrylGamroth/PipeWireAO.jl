macro _spa_ids(definitions)
    statements = Any[]
    for definition in definitions.args
        definition isa LineNumberNode && continue
        Meta.isexpr(definition, :(=), 2) || error("SPA ID groups contain assignments only")
        name, value = definition.args
        push!(statements, :(const $(esc(name)) = UInt32($(esc(value)))))
    end
    return Expr(:block, statements...)
end

# Basic SPA POD value types returned by `pod_type`.
@_spa_ids begin
    POD_NONE = LibPipeWire.SPA_TYPE_None
    POD_BOOL = LibPipeWire.SPA_TYPE_Bool
    POD_ID = LibPipeWire.SPA_TYPE_Id
    POD_INT = LibPipeWire.SPA_TYPE_Int
    POD_LONG = LibPipeWire.SPA_TYPE_Long
    POD_FLOAT = LibPipeWire.SPA_TYPE_Float
    POD_DOUBLE = LibPipeWire.SPA_TYPE_Double
    POD_STRING = LibPipeWire.SPA_TYPE_String
    POD_BYTES = LibPipeWire.SPA_TYPE_Bytes
    POD_RECTANGLE = LibPipeWire.SPA_TYPE_Rectangle
    POD_FRACTION = LibPipeWire.SPA_TYPE_Fraction
    POD_BITMAP = LibPipeWire.SPA_TYPE_Bitmap
    POD_ARRAY = LibPipeWire.SPA_TYPE_Array
    POD_STRUCT = LibPipeWire.SPA_TYPE_Struct
    POD_OBJECT = LibPipeWire.SPA_TYPE_Object
    POD_SEQUENCE = LibPipeWire.SPA_TYPE_Sequence
    POD_POINTER = LibPipeWire.SPA_TYPE_Pointer
    POD_FD = LibPipeWire.SPA_TYPE_Fd
    POD_CHOICE = LibPipeWire.SPA_TYPE_Choice
end

# Standard SPA parameter identifiers.
@_spa_ids begin
    PARAM_INVALID = LibPipeWire.SPA_PARAM_Invalid
    PARAM_PROP_INFO = LibPipeWire.SPA_PARAM_PropInfo
    PARAM_PROPS = LibPipeWire.SPA_PARAM_Props
    PARAM_ENUM_FORMAT = LibPipeWire.SPA_PARAM_EnumFormat
    PARAM_FORMAT = LibPipeWire.SPA_PARAM_Format
    PARAM_BUFFERS = LibPipeWire.SPA_PARAM_Buffers
    PARAM_META = LibPipeWire.SPA_PARAM_Meta
    PARAM_IO = LibPipeWire.SPA_PARAM_IO
    PARAM_ENUM_PROFILE = LibPipeWire.SPA_PARAM_EnumProfile
    PARAM_PROFILE = LibPipeWire.SPA_PARAM_Profile
    PARAM_ENUM_PORT_CONFIG = LibPipeWire.SPA_PARAM_EnumPortConfig
    PARAM_PORT_CONFIG = LibPipeWire.SPA_PARAM_PortConfig
    PARAM_ENUM_ROUTE = LibPipeWire.SPA_PARAM_EnumRoute
    PARAM_ROUTE = LibPipeWire.SPA_PARAM_Route
    PARAM_CONTROL = LibPipeWire.SPA_PARAM_Control
    PARAM_LATENCY = LibPipeWire.SPA_PARAM_Latency
    PARAM_PROCESS_LATENCY = LibPipeWire.SPA_PARAM_ProcessLatency
    PARAM_TAG = LibPipeWire.SPA_PARAM_Tag
    PARAM_PEER_ENUM_FORMAT = LibPipeWire.SPA_PARAM_PeerEnumFormat
    PARAM_CAPABILITY = LibPipeWire.SPA_PARAM_Capability
    PARAM_PEER_CAPABILITY = LibPipeWire.SPA_PARAM_PeerCapability
end

# Types of object-valued SPA PODs.
@_spa_ids begin
    OBJECT_PROP_INFO = LibPipeWire.SPA_TYPE_OBJECT_PropInfo
    OBJECT_PROPS = LibPipeWire.SPA_TYPE_OBJECT_Props
    OBJECT_FORMAT = LibPipeWire.SPA_TYPE_OBJECT_Format
    OBJECT_PARAM_BUFFERS = LibPipeWire.SPA_TYPE_OBJECT_ParamBuffers
    OBJECT_PARAM_META = LibPipeWire.SPA_TYPE_OBJECT_ParamMeta
    OBJECT_PARAM_IO = LibPipeWire.SPA_TYPE_OBJECT_ParamIO
    OBJECT_PARAM_PROFILE = LibPipeWire.SPA_TYPE_OBJECT_ParamProfile
    OBJECT_PARAM_PORT_CONFIG = LibPipeWire.SPA_TYPE_OBJECT_ParamPortConfig
    OBJECT_PARAM_ROUTE = LibPipeWire.SPA_TYPE_OBJECT_ParamRoute
    OBJECT_PROFILER = LibPipeWire.SPA_TYPE_OBJECT_Profiler
    OBJECT_PARAM_LATENCY = LibPipeWire.SPA_TYPE_OBJECT_ParamLatency
    OBJECT_PARAM_PROCESS_LATENCY = LibPipeWire.SPA_TYPE_OBJECT_ParamProcessLatency
    OBJECT_PARAM_TAG = LibPipeWire.SPA_TYPE_OBJECT_ParamTag
    OBJECT_PEER_PARAM = LibPipeWire.SPA_TYPE_OBJECT_PeerParam
    OBJECT_PARAM_DICT = LibPipeWire.SPA_TYPE_OBJECT_ParamDict
end

# Media types stored in SPA format objects.
@_spa_ids begin
    MEDIA_TYPE_UNKNOWN = LibPipeWire.SPA_MEDIA_TYPE_unknown
    MEDIA_TYPE_AUDIO = LibPipeWire.SPA_MEDIA_TYPE_audio
    MEDIA_TYPE_VIDEO = LibPipeWire.SPA_MEDIA_TYPE_video
    MEDIA_TYPE_IMAGE = LibPipeWire.SPA_MEDIA_TYPE_image
    MEDIA_TYPE_BINARY = LibPipeWire.SPA_MEDIA_TYPE_binary
    MEDIA_TYPE_STREAM = LibPipeWire.SPA_MEDIA_TYPE_stream
    MEDIA_TYPE_APPLICATION = LibPipeWire.SPA_MEDIA_TYPE_application
end

# Media subtypes stored in SPA format objects.
@_spa_ids begin
    MEDIA_SUBTYPE_UNKNOWN = LibPipeWire.SPA_MEDIA_SUBTYPE_unknown
    MEDIA_SUBTYPE_RAW = LibPipeWire.SPA_MEDIA_SUBTYPE_raw
    MEDIA_SUBTYPE_DSP = LibPipeWire.SPA_MEDIA_SUBTYPE_dsp
    MEDIA_SUBTYPE_IEC958 = LibPipeWire.SPA_MEDIA_SUBTYPE_iec958
    MEDIA_SUBTYPE_DSD = LibPipeWire.SPA_MEDIA_SUBTYPE_dsd
    MEDIA_SUBTYPE_MP3 = LibPipeWire.SPA_MEDIA_SUBTYPE_mp3
    MEDIA_SUBTYPE_AAC = LibPipeWire.SPA_MEDIA_SUBTYPE_aac
    MEDIA_SUBTYPE_VORBIS = LibPipeWire.SPA_MEDIA_SUBTYPE_vorbis
    MEDIA_SUBTYPE_WMA = LibPipeWire.SPA_MEDIA_SUBTYPE_wma
    MEDIA_SUBTYPE_RA = LibPipeWire.SPA_MEDIA_SUBTYPE_ra
    MEDIA_SUBTYPE_SBC = LibPipeWire.SPA_MEDIA_SUBTYPE_sbc
    MEDIA_SUBTYPE_ADPCM = LibPipeWire.SPA_MEDIA_SUBTYPE_adpcm
    MEDIA_SUBTYPE_G723 = LibPipeWire.SPA_MEDIA_SUBTYPE_g723
    MEDIA_SUBTYPE_G726 = LibPipeWire.SPA_MEDIA_SUBTYPE_g726
    MEDIA_SUBTYPE_G729 = LibPipeWire.SPA_MEDIA_SUBTYPE_g729
    MEDIA_SUBTYPE_AMR = LibPipeWire.SPA_MEDIA_SUBTYPE_amr
    MEDIA_SUBTYPE_GSM = LibPipeWire.SPA_MEDIA_SUBTYPE_gsm
    MEDIA_SUBTYPE_ALAC = LibPipeWire.SPA_MEDIA_SUBTYPE_alac
    MEDIA_SUBTYPE_FLAC = LibPipeWire.SPA_MEDIA_SUBTYPE_flac
    MEDIA_SUBTYPE_APE = LibPipeWire.SPA_MEDIA_SUBTYPE_ape
    MEDIA_SUBTYPE_OPUS = LibPipeWire.SPA_MEDIA_SUBTYPE_opus
    MEDIA_SUBTYPE_AC3 = LibPipeWire.SPA_MEDIA_SUBTYPE_ac3
    MEDIA_SUBTYPE_EAC3 = LibPipeWire.SPA_MEDIA_SUBTYPE_eac3
    MEDIA_SUBTYPE_TRUEHD = LibPipeWire.SPA_MEDIA_SUBTYPE_truehd
    MEDIA_SUBTYPE_DTS = LibPipeWire.SPA_MEDIA_SUBTYPE_dts
    MEDIA_SUBTYPE_MPEGH = LibPipeWire.SPA_MEDIA_SUBTYPE_mpegh
    MEDIA_SUBTYPE_H264 = LibPipeWire.SPA_MEDIA_SUBTYPE_h264
    MEDIA_SUBTYPE_MJPG = LibPipeWire.SPA_MEDIA_SUBTYPE_mjpg
    MEDIA_SUBTYPE_DV = LibPipeWire.SPA_MEDIA_SUBTYPE_dv
    MEDIA_SUBTYPE_MPEGTS = LibPipeWire.SPA_MEDIA_SUBTYPE_mpegts
    MEDIA_SUBTYPE_H263 = LibPipeWire.SPA_MEDIA_SUBTYPE_h263
    MEDIA_SUBTYPE_MPEG1 = LibPipeWire.SPA_MEDIA_SUBTYPE_mpeg1
    MEDIA_SUBTYPE_MPEG2 = LibPipeWire.SPA_MEDIA_SUBTYPE_mpeg2
    MEDIA_SUBTYPE_MPEG4 = LibPipeWire.SPA_MEDIA_SUBTYPE_mpeg4
    MEDIA_SUBTYPE_XVID = LibPipeWire.SPA_MEDIA_SUBTYPE_xvid
    MEDIA_SUBTYPE_VC1 = LibPipeWire.SPA_MEDIA_SUBTYPE_vc1
    MEDIA_SUBTYPE_VP8 = LibPipeWire.SPA_MEDIA_SUBTYPE_vp8
    MEDIA_SUBTYPE_VP9 = LibPipeWire.SPA_MEDIA_SUBTYPE_vp9
    MEDIA_SUBTYPE_BAYER = LibPipeWire.SPA_MEDIA_SUBTYPE_bayer
    MEDIA_SUBTYPE_H265 = LibPipeWire.SPA_MEDIA_SUBTYPE_h265
    MEDIA_SUBTYPE_JPEG = LibPipeWire.SPA_MEDIA_SUBTYPE_jpeg
    MEDIA_SUBTYPE_MIDI = LibPipeWire.SPA_MEDIA_SUBTYPE_midi
    MEDIA_SUBTYPE_CONTROL = LibPipeWire.SPA_MEDIA_SUBTYPE_control
    MEDIA_SUBTYPE_NDARRAY = LibPipeWire.SPA_MEDIA_SUBTYPE_ndarray
end

# Property keys in SPA format objects.
@_spa_ids begin
    FORMAT_MEDIA_TYPE = LibPipeWire.SPA_FORMAT_mediaType
    FORMAT_MEDIA_SUBTYPE = LibPipeWire.SPA_FORMAT_mediaSubtype
    FORMAT_AUDIO_FORMAT = LibPipeWire.SPA_FORMAT_AUDIO_format
    FORMAT_AUDIO_FLAGS = LibPipeWire.SPA_FORMAT_AUDIO_flags
    FORMAT_AUDIO_RATE = LibPipeWire.SPA_FORMAT_AUDIO_rate
    FORMAT_AUDIO_CHANNELS = LibPipeWire.SPA_FORMAT_AUDIO_channels
    FORMAT_AUDIO_POSITION = LibPipeWire.SPA_FORMAT_AUDIO_position
    FORMAT_AUDIO_IEC958_CODEC = LibPipeWire.SPA_FORMAT_AUDIO_iec958Codec
    FORMAT_AUDIO_BITORDER = LibPipeWire.SPA_FORMAT_AUDIO_bitorder
    FORMAT_AUDIO_INTERLEAVE = LibPipeWire.SPA_FORMAT_AUDIO_interleave
    FORMAT_AUDIO_BITRATE = LibPipeWire.SPA_FORMAT_AUDIO_bitrate
    FORMAT_AUDIO_BLOCK_ALIGN = LibPipeWire.SPA_FORMAT_AUDIO_blockAlign
    FORMAT_AUDIO_AAC_STREAM_FORMAT = LibPipeWire.SPA_FORMAT_AUDIO_AAC_streamFormat
    FORMAT_AUDIO_WMA_PROFILE = LibPipeWire.SPA_FORMAT_AUDIO_WMA_profile
    FORMAT_AUDIO_AMR_BAND_MODE = LibPipeWire.SPA_FORMAT_AUDIO_AMR_bandMode
    FORMAT_AUDIO_MP3_CHANNEL_MODE = LibPipeWire.SPA_FORMAT_AUDIO_MP3_channelMode
    FORMAT_AUDIO_DTS_EXT_TYPE = LibPipeWire.SPA_FORMAT_AUDIO_DTS_extType
    FORMAT_VIDEO_FORMAT = LibPipeWire.SPA_FORMAT_VIDEO_format
    FORMAT_VIDEO_MODIFIER = LibPipeWire.SPA_FORMAT_VIDEO_modifier
    FORMAT_VIDEO_SIZE = LibPipeWire.SPA_FORMAT_VIDEO_size
    FORMAT_VIDEO_FRAMERATE = LibPipeWire.SPA_FORMAT_VIDEO_framerate
    FORMAT_VIDEO_MAX_FRAMERATE = LibPipeWire.SPA_FORMAT_VIDEO_maxFramerate
    FORMAT_VIDEO_VIEWS = LibPipeWire.SPA_FORMAT_VIDEO_views
    FORMAT_VIDEO_INTERLACE_MODE = LibPipeWire.SPA_FORMAT_VIDEO_interlaceMode
    FORMAT_VIDEO_PIXEL_ASPECT_RATIO = LibPipeWire.SPA_FORMAT_VIDEO_pixelAspectRatio
    FORMAT_VIDEO_MULTIVIEW_MODE = LibPipeWire.SPA_FORMAT_VIDEO_multiviewMode
    FORMAT_VIDEO_MULTIVIEW_FLAGS = LibPipeWire.SPA_FORMAT_VIDEO_multiviewFlags
    FORMAT_VIDEO_CHROMA_SITE = LibPipeWire.SPA_FORMAT_VIDEO_chromaSite
    FORMAT_VIDEO_COLOR_RANGE = LibPipeWire.SPA_FORMAT_VIDEO_colorRange
    FORMAT_VIDEO_COLOR_MATRIX = LibPipeWire.SPA_FORMAT_VIDEO_colorMatrix
    FORMAT_VIDEO_TRANSFER_FUNCTION = LibPipeWire.SPA_FORMAT_VIDEO_transferFunction
    FORMAT_VIDEO_COLOR_PRIMARIES = LibPipeWire.SPA_FORMAT_VIDEO_colorPrimaries
    FORMAT_VIDEO_PROFILE = LibPipeWire.SPA_FORMAT_VIDEO_profile
    FORMAT_VIDEO_LEVEL = LibPipeWire.SPA_FORMAT_VIDEO_level
    FORMAT_VIDEO_H264_STREAM_FORMAT = LibPipeWire.SPA_FORMAT_VIDEO_H264_streamFormat
    FORMAT_VIDEO_H264_ALIGNMENT = LibPipeWire.SPA_FORMAT_VIDEO_H264_alignment
    FORMAT_VIDEO_H265_STREAM_FORMAT = LibPipeWire.SPA_FORMAT_VIDEO_H265_streamFormat
    FORMAT_VIDEO_H265_ALIGNMENT = LibPipeWire.SPA_FORMAT_VIDEO_H265_alignment
    FORMAT_VIDEO_DEVICE_ID = LibPipeWire.SPA_FORMAT_VIDEO_deviceId
    FORMAT_CONTROL_TYPES = LibPipeWire.SPA_FORMAT_CONTROL_types
    FORMAT_NDARRAY_ELEMENT_TYPE = LibPipeWire.SPA_FORMAT_NDARRAY_elementType
    FORMAT_NDARRAY_SHAPE = LibPipeWire.SPA_FORMAT_NDARRAY_shape
    FORMAT_NDARRAY_LAYOUT = LibPipeWire.SPA_FORMAT_NDARRAY_layout
    FORMAT_NDARRAY_RATE = LibPipeWire.SPA_FORMAT_NDARRAY_rate
end

# Property keys in SPA properties objects.
@_spa_ids begin
    PROP_UNKNOWN = LibPipeWire.SPA_PROP_unknown
    PROP_DEVICE = LibPipeWire.SPA_PROP_device
    PROP_DEVICE_NAME = LibPipeWire.SPA_PROP_deviceName
    PROP_DEVICE_FD = LibPipeWire.SPA_PROP_deviceFd
    PROP_CARD = LibPipeWire.SPA_PROP_card
    PROP_CARD_NAME = LibPipeWire.SPA_PROP_cardName
    PROP_MIN_LATENCY = LibPipeWire.SPA_PROP_minLatency
    PROP_MAX_LATENCY = LibPipeWire.SPA_PROP_maxLatency
    PROP_PERIODS = LibPipeWire.SPA_PROP_periods
    PROP_PERIOD_SIZE = LibPipeWire.SPA_PROP_periodSize
    PROP_PERIOD_EVENT = LibPipeWire.SPA_PROP_periodEvent
    PROP_LIVE = LibPipeWire.SPA_PROP_live
    PROP_RATE = LibPipeWire.SPA_PROP_rate
    PROP_QUALITY = LibPipeWire.SPA_PROP_quality
    PROP_BLUETOOTH_AUDIO_CODEC = LibPipeWire.SPA_PROP_bluetoothAudioCodec
    PROP_BLUETOOTH_OFFLOAD_ACTIVE = LibPipeWire.SPA_PROP_bluetoothOffloadActive
    PROP_CLOCK_ID = LibPipeWire.SPA_PROP_clockId
    PROP_CLOCK_DEVICE = LibPipeWire.SPA_PROP_clockDevice
    PROP_CLOCK_INTERFACE = LibPipeWire.SPA_PROP_clockInterface
    PROP_WAVE_TYPE = LibPipeWire.SPA_PROP_waveType
    PROP_FREQUENCY = LibPipeWire.SPA_PROP_frequency
    PROP_VOLUME = LibPipeWire.SPA_PROP_volume
    PROP_MUTE = LibPipeWire.SPA_PROP_mute
    PROP_PATTERN_TYPE = LibPipeWire.SPA_PROP_patternType
    PROP_DITHER_TYPE = LibPipeWire.SPA_PROP_ditherType
    PROP_TRUNCATE = LibPipeWire.SPA_PROP_truncate
    PROP_CHANNEL_VOLUMES = LibPipeWire.SPA_PROP_channelVolumes
    PROP_VOLUME_BASE = LibPipeWire.SPA_PROP_volumeBase
    PROP_VOLUME_STEP = LibPipeWire.SPA_PROP_volumeStep
    PROP_CHANNEL_MAP = LibPipeWire.SPA_PROP_channelMap
    PROP_MONITOR_MUTE = LibPipeWire.SPA_PROP_monitorMute
    PROP_MONITOR_VOLUMES = LibPipeWire.SPA_PROP_monitorVolumes
    PROP_LATENCY_OFFSET_NSEC = LibPipeWire.SPA_PROP_latencyOffsetNsec
    PROP_SOFT_MUTE = LibPipeWire.SPA_PROP_softMute
    PROP_SOFT_VOLUMES = LibPipeWire.SPA_PROP_softVolumes
    PROP_IEC958_CODECS = LibPipeWire.SPA_PROP_iec958Codecs
    PROP_VOLUME_RAMP_SAMPLES = LibPipeWire.SPA_PROP_volumeRampSamples
    PROP_VOLUME_RAMP_STEP_SAMPLES = LibPipeWire.SPA_PROP_volumeRampStepSamples
    PROP_VOLUME_RAMP_TIME = LibPipeWire.SPA_PROP_volumeRampTime
    PROP_VOLUME_RAMP_STEP_TIME = LibPipeWire.SPA_PROP_volumeRampStepTime
    PROP_VOLUME_RAMP_SCALE = LibPipeWire.SPA_PROP_volumeRampScale
    PROP_BRIGHTNESS = LibPipeWire.SPA_PROP_brightness
    PROP_CONTRAST = LibPipeWire.SPA_PROP_contrast
    PROP_SATURATION = LibPipeWire.SPA_PROP_saturation
    PROP_HUE = LibPipeWire.SPA_PROP_hue
    PROP_GAMMA = LibPipeWire.SPA_PROP_gamma
    PROP_EXPOSURE = LibPipeWire.SPA_PROP_exposure
    PROP_GAIN = LibPipeWire.SPA_PROP_gain
    PROP_SHARPNESS = LibPipeWire.SPA_PROP_sharpness
    PROP_PARAMS = LibPipeWire.SPA_PROP_params
end

# Storage types used by SPA buffer data.
@_spa_ids begin
    DATA_INVALID = LibPipeWire.SPA_DATA_Invalid
    DATA_MEM_PTR = LibPipeWire.SPA_DATA_MemPtr
    DATA_MEM_FD = LibPipeWire.SPA_DATA_MemFd
    DATA_DMA_BUF = LibPipeWire.SPA_DATA_DmaBuf
    DATA_MEM_ID = LibPipeWire.SPA_DATA_MemId
    DATA_SYNC_OBJECT = LibPipeWire.SPA_DATA_SyncObj
end

# Access flags stored in `spa_data.flags`.
const DATA_FLAG_NONE = UInt32(0)
const DATA_FLAG_READABLE = UInt32(1 << 0)
const DATA_FLAG_WRITABLE = UInt32(1 << 1)
const DATA_FLAG_DYNAMIC = UInt32(1 << 2)
const DATA_FLAG_READWRITE = DATA_FLAG_READABLE | DATA_FLAG_WRITABLE
const DATA_FLAG_MAPPABLE = UInt32(1 << 3)
const DATA_FLAG_HUGE_PAGES = UInt32(1 << 4)
const DATA_FLAG_HUGE_2MB = UInt32(1 << 5)
const DATA_FLAG_HUGE_1GB = UInt32(1 << 6)

# Metadata types attached to SPA buffers.
@_spa_ids begin
    META_INVALID = LibPipeWire.SPA_META_Invalid
    META_HEADER = LibPipeWire.SPA_META_Header
    META_VIDEO_CROP = LibPipeWire.SPA_META_VideoCrop
    META_VIDEO_DAMAGE = LibPipeWire.SPA_META_VideoDamage
    META_BITMAP = LibPipeWire.SPA_META_Bitmap
    META_CURSOR = LibPipeWire.SPA_META_Cursor
    META_CONTROL = LibPipeWire.SPA_META_Control
    META_BUSY = LibPipeWire.SPA_META_Busy
    META_VIDEO_TRANSFORM = LibPipeWire.SPA_META_VideoTransform
    META_SYNC_TIMELINE = LibPipeWire.SPA_META_SyncTimeline
    META_ACQUISITION = LibPipeWire.SPA_META_Acquisition
end

# Flags stored in `spa_meta_header.flags`.
const META_HEADER_FLAG_DISCONT = UInt32(1 << 0)
const META_HEADER_FLAG_CORRUPTED = UInt32(1 << 1)
const META_HEADER_FLAG_MARKER = UInt32(1 << 2)
const META_HEADER_FLAG_HEADER = UInt32(1 << 3)
const META_HEADER_FLAG_GAP = UInt32(1 << 4)
const META_HEADER_FLAG_DELTA_UNIT = UInt32(1 << 5)

# Flags stored in `spa_chunk.flags`.
const CHUNK_FLAG_NONE = Int32(0)
const CHUNK_FLAG_CORRUPTED = Int32(1 << 0)
const CHUNK_FLAG_EMPTY = Int32(1 << 1)

# Video transformations stored in SPA buffer metadata.
@_spa_ids begin
    META_TRANSFORM_NONE = LibPipeWire.SPA_META_TRANSFORMATION_None
    META_TRANSFORM_90 = LibPipeWire.SPA_META_TRANSFORMATION_90
    META_TRANSFORM_180 = LibPipeWire.SPA_META_TRANSFORMATION_180
    META_TRANSFORM_270 = LibPipeWire.SPA_META_TRANSFORMATION_270
    META_TRANSFORM_FLIPPED = LibPipeWire.SPA_META_TRANSFORMATION_Flipped
    META_TRANSFORM_FLIPPED_90 = LibPipeWire.SPA_META_TRANSFORMATION_Flipped90
    META_TRANSFORM_FLIPPED_180 = LibPipeWire.SPA_META_TRANSFORMATION_Flipped180
    META_TRANSFORM_FLIPPED_270 = LibPipeWire.SPA_META_TRANSFORMATION_Flipped270
end

# SPA I/O area types.
@_spa_ids begin
    IO_INVALID = LibPipeWire.SPA_IO_Invalid
    IO_BUFFERS = LibPipeWire.SPA_IO_Buffers
    IO_RANGE = LibPipeWire.SPA_IO_Range
    IO_CLOCK = LibPipeWire.SPA_IO_Clock
    IO_LATENCY = LibPipeWire.SPA_IO_Latency
    IO_CONTROL = LibPipeWire.SPA_IO_Control
    IO_NOTIFY = LibPipeWire.SPA_IO_Notify
    IO_POSITION = LibPipeWire.SPA_IO_Position
    IO_RATE_MATCH = LibPipeWire.SPA_IO_RateMatch
    IO_MEMORY = LibPipeWire.SPA_IO_Memory
    IO_ASYNC_BUFFERS = LibPipeWire.SPA_IO_AsyncBuffers
end

# Property keys in SPA buffer-layout parameters.
@_spa_ids begin
    BUFFERS_COUNT = LibPipeWire.SPA_PARAM_BUFFERS_buffers
    BUFFERS_BLOCKS = LibPipeWire.SPA_PARAM_BUFFERS_blocks
    BUFFERS_SIZE = LibPipeWire.SPA_PARAM_BUFFERS_size
    BUFFERS_STRIDE = LibPipeWire.SPA_PARAM_BUFFERS_stride
    BUFFERS_ALIGN = LibPipeWire.SPA_PARAM_BUFFERS_align
    BUFFERS_DATA_TYPES = LibPipeWire.SPA_PARAM_BUFFERS_dataType
    BUFFERS_META_TYPES = LibPipeWire.SPA_PARAM_BUFFERS_metaType
    BUFFERS_PAGE_SIZE_HINT = LibPipeWire.SPA_PARAM_BUFFERS_pageSizeHint
end

# Property keys in SPA buffer-metadata parameters.
@_spa_ids begin
    META_PARAM_TYPE = LibPipeWire.SPA_PARAM_META_type
    META_PARAM_SIZE = LibPipeWire.SPA_PARAM_META_size
    META_PARAM_FEATURES = LibPipeWire.SPA_PARAM_META_features
end

# Property keys in SPA I/O-area parameters.
@_spa_ids begin
    IO_PARAM_ID = LibPipeWire.SPA_PARAM_IO_id
    IO_PARAM_SIZE = LibPipeWire.SPA_PARAM_IO_size
end

# Property keys in SPA latency parameters.
@_spa_ids begin
    LATENCY_DIRECTION = LibPipeWire.SPA_PARAM_LATENCY_direction
    LATENCY_MIN_QUANTUM = LibPipeWire.SPA_PARAM_LATENCY_minQuantum
    LATENCY_MAX_QUANTUM = LibPipeWire.SPA_PARAM_LATENCY_maxQuantum
    LATENCY_MIN_RATE = LibPipeWire.SPA_PARAM_LATENCY_minRate
    LATENCY_MAX_RATE = LibPipeWire.SPA_PARAM_LATENCY_maxRate
    LATENCY_MIN_NS = LibPipeWire.SPA_PARAM_LATENCY_minNs
    LATENCY_MAX_NS = LibPipeWire.SPA_PARAM_LATENCY_maxNs
end

# Property keys in SPA processing-latency parameters.
@_spa_ids begin
    PROCESS_LATENCY_QUANTUM = LibPipeWire.SPA_PARAM_PROCESS_LATENCY_quantum
    PROCESS_LATENCY_RATE = LibPipeWire.SPA_PARAM_PROCESS_LATENCY_rate
    PROCESS_LATENCY_NS = LibPipeWire.SPA_PARAM_PROCESS_LATENCY_ns
end

# SPA port-configuration modes.
@_spa_ids begin
    PORT_CONFIG_MODE_NONE = LibPipeWire.SPA_PARAM_PORT_CONFIG_MODE_none
    PORT_CONFIG_MODE_PASSTHROUGH = LibPipeWire.SPA_PARAM_PORT_CONFIG_MODE_passthrough
    PORT_CONFIG_MODE_CONVERT = LibPipeWire.SPA_PARAM_PORT_CONFIG_MODE_convert
    PORT_CONFIG_MODE_DSP = LibPipeWire.SPA_PARAM_PORT_CONFIG_MODE_dsp
end

# Property keys in SPA port-configuration parameters.
@_spa_ids begin
    PORT_CONFIG_DIRECTION = LibPipeWire.SPA_PARAM_PORT_CONFIG_direction
    PORT_CONFIG_MODE = LibPipeWire.SPA_PARAM_PORT_CONFIG_mode
    PORT_CONFIG_MONITOR = LibPipeWire.SPA_PARAM_PORT_CONFIG_monitor
    PORT_CONFIG_CONTROL = LibPipeWire.SPA_PARAM_PORT_CONFIG_control
    PORT_CONFIG_FORMAT = LibPipeWire.SPA_PARAM_PORT_CONFIG_format
end

# Property keys in SPA profile parameters.
@_spa_ids begin
    PROFILE_INDEX = LibPipeWire.SPA_PARAM_PROFILE_index
    PROFILE_NAME = LibPipeWire.SPA_PARAM_PROFILE_name
    PROFILE_DESCRIPTION = LibPipeWire.SPA_PARAM_PROFILE_description
    PROFILE_PRIORITY = LibPipeWire.SPA_PARAM_PROFILE_priority
    PROFILE_AVAILABLE = LibPipeWire.SPA_PARAM_PROFILE_available
    PROFILE_INFO = LibPipeWire.SPA_PARAM_PROFILE_info
    PROFILE_CLASSES = LibPipeWire.SPA_PARAM_PROFILE_classes
    PROFILE_SAVE = LibPipeWire.SPA_PARAM_PROFILE_save
end

# Property keys in SPA property-information objects.
@_spa_ids begin
    PROP_INFO_ID = LibPipeWire.SPA_PROP_INFO_id
    PROP_INFO_NAME = LibPipeWire.SPA_PROP_INFO_name
    PROP_INFO_TYPE = LibPipeWire.SPA_PROP_INFO_type
    PROP_INFO_LABELS = LibPipeWire.SPA_PROP_INFO_labels
    PROP_INFO_CONTAINER = LibPipeWire.SPA_PROP_INFO_container
    PROP_INFO_PARAMS = LibPipeWire.SPA_PROP_INFO_params
    PROP_INFO_DESCRIPTION = LibPipeWire.SPA_PROP_INFO_description
    PROP_INFO_GROUP = LibPipeWire.SPA_PROP_INFO_group
end

# Property keys in SPA route parameters.
@_spa_ids begin
    ROUTE_INDEX = LibPipeWire.SPA_PARAM_ROUTE_index
    ROUTE_DIRECTION = LibPipeWire.SPA_PARAM_ROUTE_direction
    ROUTE_DEVICE = LibPipeWire.SPA_PARAM_ROUTE_device
    ROUTE_NAME = LibPipeWire.SPA_PARAM_ROUTE_name
    ROUTE_DESCRIPTION = LibPipeWire.SPA_PARAM_ROUTE_description
    ROUTE_PRIORITY = LibPipeWire.SPA_PARAM_ROUTE_priority
    ROUTE_AVAILABLE = LibPipeWire.SPA_PARAM_ROUTE_available
    ROUTE_INFO = LibPipeWire.SPA_PARAM_ROUTE_info
    ROUTE_PROFILES = LibPipeWire.SPA_PARAM_ROUTE_profiles
    ROUTE_PROPS = LibPipeWire.SPA_PARAM_ROUTE_props
    ROUTE_DEVICES = LibPipeWire.SPA_PARAM_ROUTE_devices
    ROUTE_PROFILE = LibPipeWire.SPA_PARAM_ROUTE_profile
    ROUTE_SAVE = LibPipeWire.SPA_PARAM_ROUTE_save
end

# Property keys in SPA tag parameters.
@_spa_ids begin
    TAG_DIRECTION = LibPipeWire.SPA_PARAM_TAG_direction
    TAG_INFO = LibPipeWire.SPA_PARAM_TAG_info
end

# Standard commands sent to SPA nodes.
@_spa_ids begin
    NODE_COMMAND_SUSPEND = LibPipeWire.SPA_NODE_COMMAND_Suspend
    NODE_COMMAND_PAUSE = LibPipeWire.SPA_NODE_COMMAND_Pause
    NODE_COMMAND_START = LibPipeWire.SPA_NODE_COMMAND_Start
    NODE_COMMAND_ENABLE = LibPipeWire.SPA_NODE_COMMAND_Enable
    NODE_COMMAND_DISABLE = LibPipeWire.SPA_NODE_COMMAND_Disable
    NODE_COMMAND_FLUSH = LibPipeWire.SPA_NODE_COMMAND_Flush
    NODE_COMMAND_DRAIN = LibPipeWire.SPA_NODE_COMMAND_Drain
    NODE_COMMAND_MARKER = LibPipeWire.SPA_NODE_COMMAND_Marker
    NODE_COMMAND_PARAM_BEGIN = LibPipeWire.SPA_NODE_COMMAND_ParamBegin
    NODE_COMMAND_PARAM_END = LibPipeWire.SPA_NODE_COMMAND_ParamEnd
    NODE_COMMAND_REQUEST_PROCESS = LibPipeWire.SPA_NODE_COMMAND_RequestProcess
    NODE_COMMAND_USER = LibPipeWire.SPA_NODE_COMMAND_User
end

# Standard events emitted by SPA nodes.
@_spa_ids begin
    NODE_EVENT_ERROR = LibPipeWire.SPA_NODE_EVENT_Error
    NODE_EVENT_BUFFERING = LibPipeWire.SPA_NODE_EVENT_Buffering
    NODE_EVENT_REQUEST_REFRESH = LibPipeWire.SPA_NODE_EVENT_RequestRefresh
    NODE_EVENT_REQUEST_PROCESS = LibPipeWire.SPA_NODE_EVENT_RequestProcess
    NODE_EVENT_USER = LibPipeWire.SPA_NODE_EVENT_User
end
