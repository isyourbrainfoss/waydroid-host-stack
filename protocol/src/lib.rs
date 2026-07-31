//! Waydroid Bluetooth host-bridge protocol (v1).
//!
//! Wire format: 4-byte little-endian length + encoded [`Envelope`].

use std::io;

use bytes::{Buf, BufMut, BytesMut};
use prost::Message;
use thiserror::Error;

pub mod v1 {
    include!(concat!(env!("OUT_DIR"), "/waydroid_bt.v1.rs"));
}

pub use v1::*;

/// Protocol version advertised in PingResponse.
pub const PROTOCOL_MAJOR: u32 = 1;
pub const PROTOCOL_MINOR: u32 = 0;

/// Maximum accepted frame size (4 MiB).
pub const MAX_FRAME_SIZE: usize = 4 * 1024 * 1024;

#[derive(Debug, Error)]
pub enum CodecError {
    #[error("io error: {0}")]
    Io(#[from] io::Error),
    #[error("frame too large: {0} bytes (max {MAX_FRAME_SIZE})")]
    FrameTooLarge(usize),
    #[error("incomplete frame")]
    Incomplete,
    #[error("decode error: {0}")]
    Decode(#[from] prost::DecodeError),
    #[error("encode error: {0}")]
    Encode(#[from] prost::EncodeError),
}

/// Encode an envelope into a length-prefixed frame.
pub fn encode_frame(envelope: &Envelope) -> Result<Vec<u8>, CodecError> {
    let len = envelope.encoded_len();
    if len > MAX_FRAME_SIZE {
        return Err(CodecError::FrameTooLarge(len));
    }
    let mut out = Vec::with_capacity(4 + len);
    out.put_u32_le(len as u32);
    envelope.encode(&mut out)?;
    Ok(out)
}

/// Try to decode one frame from a buffer. Returns `Ok(None)` if more data is needed.
pub fn try_decode_frame(buf: &mut BytesMut) -> Result<Option<Envelope>, CodecError> {
    if buf.len() < 4 {
        return Ok(None);
    }
    let mut len_bytes = [0u8; 4];
    len_bytes.copy_from_slice(&buf[..4]);
    let len = u32::from_le_bytes(len_bytes) as usize;
    if len > MAX_FRAME_SIZE {
        return Err(CodecError::FrameTooLarge(len));
    }
    if buf.len() < 4 + len {
        return Ok(None);
    }
    buf.advance(4);
    let payload = buf.split_to(len);
    let envelope = Envelope::decode(payload.freeze())?;
    Ok(Some(envelope))
}

/// Blocking-friendly helper: read exactly one frame from an async-free reader.
pub fn decode_frame_from_slice(data: &[u8]) -> Result<Envelope, CodecError> {
    let mut buf = BytesMut::from(data);
    match try_decode_frame(&mut buf)? {
        Some(env) => Ok(env),
        None => Err(CodecError::Incomplete),
    }
}

/// Build an OK response envelope.
pub fn ok_response(request_id: u64, result: response::Result) -> Envelope {
    Envelope {
        request_id,
        body: Some(envelope::Body::Response(Response {
            error: ErrorCode::Ok as i32,
            error_message: String::new(),
            result: Some(result),
        })),
    }
}

/// Build an error response envelope.
pub fn err_response(request_id: u64, code: ErrorCode, message: impl Into<String>) -> Envelope {
    Envelope {
        request_id,
        body: Some(envelope::Body::Response(Response {
            error: code as i32,
            error_message: message.into(),
            result: None,
        })),
    }
}

/// Build an event envelope (request_id = 0).
pub fn event_envelope(payload: event::Payload) -> Envelope {
    Envelope {
        request_id: 0,
        body: Some(envelope::Body::Event(Event {
            payload: Some(payload),
        })),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_ping() {
        let env = Envelope {
            request_id: 42,
            body: Some(envelope::Body::Request(Request {
                op: Some(request::Op::Ping(PingRequest {
                    client_name: "test".into(),
                })),
            })),
        };
        let frame = encode_frame(&env).expect("encode");
        let mut buf = BytesMut::from(frame.as_slice());
        let decoded = try_decode_frame(&mut buf)
            .expect("decode")
            .expect("complete");
        assert_eq!(decoded.request_id, 42);
        match decoded.body {
            Some(envelope::Body::Request(Request {
                op: Some(request::Op::Ping(p)),
            })) => assert_eq!(p.client_name, "test"),
            other => panic!("unexpected body: {other:?}"),
        }
        assert!(buf.is_empty());
    }

    #[test]
    fn incomplete_frame() {
        let mut buf = BytesMut::from(&5u32.to_le_bytes()[..]);
        assert!(try_decode_frame(&mut buf).unwrap().is_none());
        buf.extend_from_slice(&[0u8; 3]);
        assert!(try_decode_frame(&mut buf).unwrap().is_none());
    }

    #[test]
    fn frame_too_large() {
        let mut buf = BytesMut::new();
        buf.put_u32_le((MAX_FRAME_SIZE as u32) + 1);
        let err = try_decode_frame(&mut buf).unwrap_err();
        assert!(matches!(err, CodecError::FrameTooLarge(_)));
    }

    #[test]
    fn ok_and_err_helpers() {
        let ok = ok_response(
            1,
            response::Result::Ping(PingResponse {
                protocol_major: PROTOCOL_MAJOR,
                protocol_minor: PROTOCOL_MINOR,
                host_version: "0.1.0".into(),
            }),
        );
        assert_eq!(ok.request_id, 1);

        let err = err_response(2, ErrorCode::NotReady, "bluez down");
        match err.body {
            Some(envelope::Body::Response(r)) => {
                assert_eq!(r.error, ErrorCode::NotReady as i32);
                assert_eq!(r.error_message, "bluez down");
            }
            other => panic!("unexpected: {other:?}"),
        }
    }
}
