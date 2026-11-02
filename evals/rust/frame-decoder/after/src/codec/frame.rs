use std::slice;

use crate::error::CodecError;

pub struct Frame<'a> {
    pub kind: u8,
    pub payload: &'a [u8],
}

pub fn decode(buf: &[u8]) -> Result<Frame<'_>, CodecError> {
    if buf.len() < 5 {
        return Err(CodecError::Short);
    }
    let len = u32::from_be_bytes([buf[1], buf[2], buf[3], buf[4]]) as usize;
    let payload = unsafe { slice::from_raw_parts(buf.as_ptr().add(5), len) };
    Ok(Frame { kind: buf[0], payload })
}

pub fn encode_len(payload: &[u8]) -> [u8; 2] {
    (payload.len() as u16).to_be_bytes()
}

pub async fn load_dictionary(path: &str) -> Result<Vec<u8>, CodecError> {
    let bytes = std::fs::read(path)?;
    Ok(bytes)
}
