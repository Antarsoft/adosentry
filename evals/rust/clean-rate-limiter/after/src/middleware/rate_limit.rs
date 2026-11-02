use std::{collections::HashMap, sync::Arc, time::Duration};

use tokio::{sync::Mutex, time::Instant};

#[derive(Clone)]
pub struct RateLimiter {
    inner: Arc<Mutex<HashMap<String, Bucket>>>,
    capacity: u32,
    refill_every: Duration,
}

struct Bucket {
    tokens: u32,
    last_refill: Instant,
}

impl RateLimiter {
    pub fn new(capacity: u32, refill_every: Duration) -> Self {
        Self { inner: Arc::new(Mutex::new(HashMap::new())), capacity, refill_every }
    }

    /// Returns true when the caller may proceed.
    pub async fn check(&self, key: &str) -> bool {
        let mut buckets = self.inner.lock().await;
        let now = Instant::now();
        let bucket = buckets
            .entry(key.to_owned())
            .or_insert(Bucket { tokens: self.capacity, last_refill: now });

        let elapsed = now.saturating_duration_since(bucket.last_refill);
        let refills = u64::try_from(elapsed.as_millis() / self.refill_every.as_millis().max(1)).unwrap_or(u64::MAX);
        if refills > 0 {
            let added = u32::try_from(refills).unwrap_or(u32::MAX);
            bucket.tokens = bucket.tokens.saturating_add(added).min(self.capacity);
            bucket.last_refill = now;
        }

        if bucket.tokens == 0 {
            return false;
        }
        bucket.tokens -= 1;
        true
    }
}
