pub const Error = error{
    ModelNotFound,
    MmprojNotFound,
    ImageNotFound,
    BackendInitFailed,
    BackendInferenceFailed,
    Utf8DecodeFailed,
    OutOfMemory,
    UnsupportedRequest,
};
