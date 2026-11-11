use std::str::FromStr;
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use farpilot_core::pairing::{PairingTokenRecord, pairing_token_digest};
use sha2::{Digest, Sha256};
use sqlx::migrate::MigrateError;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{FromRow, Row, Sqlite, SqlitePool, Transaction};
use thiserror::Error;
use uuid::Uuid;

static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./migrations");

#[derive(Clone)]
pub struct GatewayStore {
    pool: SqlitePool,
}

#[derive(Clone, Debug, Eq, FromRow, PartialEq)]
pub struct HostRecord {
    pub id: String,
    pub display_name: String,
    pub public_key: Vec<u8>,
    pub fingerprint: String,
    pub enrolled_at_ms: i64,
    pub revoked_at_ms: Option<i64>,
}

#[derive(Clone, Debug, Eq, FromRow, PartialEq)]
pub struct PairingPreview {
    pub host_id: String,
    pub host_display_name: String,
    pub expires_at_ms: i64,
}

#[derive(Clone, Debug, Eq, FromRow, PartialEq)]
pub struct DeviceRecord {
    pub id: String,
    pub display_name: String,
    pub ssh_public_key: String,
    pub fingerprint: String,
    pub created_at_ms: i64,
    pub last_used_at_ms: Option<i64>,
    pub revoked_at_ms: Option<i64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuditEvent {
    pub actor_type: String,
    pub actor_id: Option<String>,
    pub action: String,
    pub target_type: Option<String>,
    pub target_id: Option<String>,
    pub outcome: String,
    pub bytes_in: i64,
    pub bytes_out: i64,
}

#[derive(Clone, Debug, Eq, FromRow, PartialEq)]
pub struct StoredAuditEvent {
    pub id: i64,
    pub occurred_at_ms: i64,
    pub actor_type: String,
    pub actor_id: Option<String>,
    pub action: String,
    pub target_type: Option<String>,
    pub target_id: Option<String>,
    pub outcome: String,
    pub bytes_in: i64,
    pub bytes_out: i64,
}

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("database operation failed")]
    Database(#[from] sqlx::Error),
    #[error("database migration failed")]
    Migration(#[from] MigrateError),
    #[error("pairing token is invalid")]
    InvalidPairingToken,
    #[error("device is revoked")]
    DeviceRevoked,
    #[error("timestamp cannot be represented")]
    InvalidTimestamp,
}

impl PartialEq for StoreError {
    fn eq(&self, other: &Self) -> bool {
        matches!(
            (self, other),
            (Self::InvalidPairingToken, Self::InvalidPairingToken)
                | (Self::DeviceRevoked, Self::DeviceRevoked)
                | (Self::InvalidTimestamp, Self::InvalidTimestamp)
        )
    }
}

impl GatewayStore {
    pub async fn connect(database_url: &str) -> Result<Self, StoreError> {
        let options = SqliteConnectOptions::from_str(database_url)?
            .create_if_missing(true)
            .foreign_keys(true);
        let max_connections = if database_url.contains(":memory:") {
            1
        } else {
            5
        };
        let pool = SqlitePoolOptions::new()
            .max_connections(max_connections)
            .connect_with(options)
            .await?;
        MIGRATOR.run(&pool).await?;
        Ok(Self { pool })
    }

    pub async fn enroll_host(
        &self,
        display_name: &str,
        public_key: &[u8],
    ) -> Result<HostRecord, StoreError> {
        let enrolled_at_ms = system_time_ms(SystemTime::now())?;
        let host = HostRecord {
            id: opaque_id("host"),
            display_name: display_name.to_owned(),
            public_key: public_key.to_vec(),
            fingerprint: fingerprint(public_key),
            enrolled_at_ms,
            revoked_at_ms: None,
        };
        sqlx::query(
            "INSERT INTO hosts \
             (id, display_name, public_key, fingerprint, enrolled_at_ms, revoked_at_ms) \
             VALUES (?, ?, ?, ?, ?, NULL)",
        )
        .bind(&host.id)
        .bind(&host.display_name)
        .bind(&host.public_key)
        .bind(&host.fingerprint)
        .bind(host.enrolled_at_ms)
        .execute(&self.pool)
        .await?;
        Ok(host)
    }

    pub async fn add_device(
        &self,
        display_name: &str,
        ssh_public_key: &str,
    ) -> Result<DeviceRecord, StoreError> {
        let created_at_ms = system_time_ms(SystemTime::now())?;
        let device = DeviceRecord {
            id: opaque_id("device"),
            display_name: display_name.to_owned(),
            ssh_public_key: ssh_public_key.to_owned(),
            fingerprint: fingerprint(ssh_public_key.as_bytes()),
            created_at_ms,
            last_used_at_ms: None,
            revoked_at_ms: None,
        };
        sqlx::query(
            "INSERT INTO devices \
             (id, display_name, ssh_public_key, fingerprint, created_at_ms, last_used_at_ms, revoked_at_ms) \
             VALUES (?, ?, ?, ?, ?, NULL, NULL)",
        )
        .bind(&device.id)
        .bind(&device.display_name)
        .bind(&device.ssh_public_key)
        .bind(&device.fingerprint)
        .bind(device.created_at_ms)
        .execute(&self.pool)
        .await?;
        Ok(device)
    }

    pub async fn grant_device(&self, device_id: &str, host_id: &str) -> Result<(), StoreError> {
        let now_ms = system_time_ms(SystemTime::now())?;
        let result = sqlx::query(
            "INSERT INTO device_host_grants \
             (device_id, host_id, created_at_ms, revoked_at_ms) \
             SELECT ?, ?, ?, NULL \
             WHERE EXISTS (SELECT 1 FROM devices WHERE id = ? AND revoked_at_ms IS NULL) \
               AND EXISTS (SELECT 1 FROM hosts WHERE id = ? AND revoked_at_ms IS NULL) \
             ON CONFLICT(device_id, host_id) DO UPDATE SET revoked_at_ms = NULL",
        )
        .bind(device_id)
        .bind(host_id)
        .bind(now_ms)
        .bind(device_id)
        .bind(host_id)
        .execute(&self.pool)
        .await?;
        if result.rows_affected() != 1 {
            return Err(StoreError::DeviceRevoked);
        }
        Ok(())
    }

    pub async fn device_can_access(
        &self,
        device_id: &str,
        host_id: &str,
    ) -> Result<bool, StoreError> {
        let count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM device_host_grants g \
             JOIN devices d ON d.id = g.device_id \
             JOIN hosts h ON h.id = g.host_id \
             WHERE g.device_id = ? AND g.host_id = ? \
               AND g.revoked_at_ms IS NULL \
               AND d.revoked_at_ms IS NULL \
               AND h.revoked_at_ms IS NULL",
        )
        .bind(device_id)
        .bind(host_id)
        .fetch_one(&self.pool)
        .await?;
        Ok(count == 1)
    }

    pub async fn revoke_device(&self, device_id: &str) -> Result<(), StoreError> {
        let now_ms = system_time_ms(SystemTime::now())?;
        let mut transaction = self.pool.begin().await?;
        sqlx::query("UPDATE devices SET revoked_at_ms = ? WHERE id = ?")
            .bind(now_ms)
            .bind(device_id)
            .execute(&mut *transaction)
            .await?;
        sqlx::query(
            "UPDATE device_host_grants SET revoked_at_ms = ? \
             WHERE device_id = ? AND revoked_at_ms IS NULL",
        )
        .bind(now_ms)
        .bind(device_id)
        .execute(&mut *transaction)
        .await?;
        insert_audit(
            &mut transaction,
            now_ms,
            &AuditEvent {
                actor_type: "operator".into(),
                actor_id: None,
                action: "device.revoked".into(),
                target_type: Some("device".into()),
                target_id: Some(device_id.to_owned()),
                outcome: "success".into(),
                bytes_in: 0,
                bytes_out: 0,
            },
        )
        .await?;
        transaction.commit().await?;
        Ok(())
    }

    pub async fn insert_host_enrollment_token(
        &self,
        record: PairingTokenRecord,
    ) -> Result<(), StoreError> {
        sqlx::query(
            "INSERT INTO host_enrollment_tokens \
             (digest, created_at_ms, expires_at_ms, consumed_at_ms) \
             VALUES (?, ?, ?, NULL)",
        )
        .bind(record.digest().to_vec())
        .bind(system_time_ms(record.created_at())?)
        .bind(system_time_ms(record.expires_at())?)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn consume_host_enrollment_token_and_enroll(
        &self,
        secret: &str,
        display_name: &str,
        public_key: &[u8],
        now: SystemTime,
    ) -> Result<HostRecord, StoreError> {
        let now_ms = system_time_ms(now)?;
        let mut transaction = self.pool.begin().await?;
        let consumed = sqlx::query(
            "UPDATE host_enrollment_tokens SET consumed_at_ms = ? \
             WHERE digest = ? AND consumed_at_ms IS NULL AND expires_at_ms > ?",
        )
        .bind(now_ms)
        .bind(pairing_token_digest(secret).to_vec())
        .bind(now_ms)
        .execute(&mut *transaction)
        .await?;
        if consumed.rows_affected() != 1 {
            return Err(StoreError::InvalidPairingToken);
        }

        let host = HostRecord {
            id: opaque_id("host"),
            display_name: display_name.to_owned(),
            public_key: public_key.to_vec(),
            fingerprint: fingerprint(public_key),
            enrolled_at_ms: now_ms,
            revoked_at_ms: None,
        };
        sqlx::query(
            "INSERT INTO hosts \
             (id, display_name, public_key, fingerprint, enrolled_at_ms, revoked_at_ms) \
             VALUES (?, ?, ?, ?, ?, NULL)",
        )
        .bind(&host.id)
        .bind(&host.display_name)
        .bind(&host.public_key)
        .bind(&host.fingerprint)
        .bind(host.enrolled_at_ms)
        .execute(&mut *transaction)
        .await?;
        insert_audit(
            &mut transaction,
            now_ms,
            &AuditEvent {
                actor_type: "operator".into(),
                actor_id: None,
                action: "host.enrolled".into(),
                target_type: Some("host".into()),
                target_id: Some(host.id.clone()),
                outcome: "success".into(),
                bytes_in: 0,
                bytes_out: 0,
            },
        )
        .await?;
        transaction.commit().await?;
        Ok(host)
    }

    pub async fn pairing_preview(
        &self,
        secret: &str,
        now: SystemTime,
    ) -> Result<Option<PairingPreview>, StoreError> {
        let now_ms = system_time_ms(now)?;
        Ok(sqlx::query_as::<_, PairingPreview>(
            "SELECT p.host_id, h.display_name AS host_display_name, p.expires_at_ms \
             FROM pairing_tokens p JOIN hosts h ON h.id = p.host_id \
             WHERE p.digest = ? AND p.consumed_at_ms IS NULL AND p.expires_at_ms > ? \
               AND h.revoked_at_ms IS NULL",
        )
        .bind(pairing_token_digest(secret).to_vec())
        .bind(now_ms)
        .fetch_optional(&self.pool)
        .await?)
    }

    pub async fn host_public_key(&self, host_id: &str) -> Result<Option<Vec<u8>>, StoreError> {
        Ok(sqlx::query_scalar(
            "SELECT public_key FROM hosts WHERE id = ? AND revoked_at_ms IS NULL",
        )
        .bind(host_id)
        .fetch_optional(&self.pool)
        .await?)
    }

    pub async fn device_ssh_key(&self, device_id: &str) -> Result<Option<String>, StoreError> {
        Ok(sqlx::query_scalar(
            "SELECT ssh_public_key FROM devices WHERE id = ? AND revoked_at_ms IS NULL",
        )
        .bind(device_id)
        .fetch_optional(&self.pool)
        .await?)
    }

    pub async fn authorized_hosts_for_device(
        &self,
        device_id: &str,
    ) -> Result<Vec<HostRecord>, StoreError> {
        Ok(sqlx::query_as::<_, HostRecord>(
            "SELECT h.id, h.display_name, h.public_key, h.fingerprint, h.enrolled_at_ms, h.revoked_at_ms \
             FROM hosts h \
             JOIN device_host_grants g ON g.host_id = h.id \
             JOIN devices d ON d.id = g.device_id \
             WHERE d.id = ? AND d.revoked_at_ms IS NULL \
               AND g.revoked_at_ms IS NULL AND h.revoked_at_ms IS NULL \
             ORDER BY h.display_name, h.id",
        )
        .bind(device_id)
        .fetch_all(&self.pool)
        .await?)
    }

    pub async fn insert_pairing_token(&self, record: PairingTokenRecord) -> Result<(), StoreError> {
        sqlx::query(
            "INSERT INTO pairing_tokens \
             (digest, host_id, created_at_ms, expires_at_ms, consumed_at_ms) \
             VALUES (?, ?, ?, ?, NULL)",
        )
        .bind(record.digest().to_vec())
        .bind(record.host_id())
        .bind(system_time_ms(record.created_at())?)
        .bind(system_time_ms(record.expires_at())?)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn consume_pairing_token_and_add_device(
        &self,
        secret: &str,
        display_name: &str,
        ssh_public_key: &str,
        now: SystemTime,
    ) -> Result<DeviceRecord, StoreError> {
        let now_ms = system_time_ms(now)?;
        let mut transaction = self.pool.begin().await?;
        let host_id: Option<String> = sqlx::query_scalar(
            "UPDATE pairing_tokens SET consumed_at_ms = ? \
             WHERE digest = ? AND consumed_at_ms IS NULL AND expires_at_ms > ? \
             RETURNING host_id",
        )
        .bind(now_ms)
        .bind(pairing_token_digest(secret).to_vec())
        .bind(now_ms)
        .fetch_optional(&mut *transaction)
        .await?;
        let host_id = host_id.ok_or(StoreError::InvalidPairingToken)?;

        let fingerprint = fingerprint(ssh_public_key.as_bytes());
        let candidate_id = opaque_id("device");
        let device = sqlx::query_as::<_, DeviceRecord>(
            "INSERT INTO devices \
             (id, display_name, ssh_public_key, fingerprint, created_at_ms, last_used_at_ms, revoked_at_ms) \
             VALUES (?, ?, ?, ?, ?, NULL, NULL) \
             ON CONFLICT(ssh_public_key) DO UPDATE SET display_name = excluded.display_name \
             RETURNING id, display_name, ssh_public_key, fingerprint, created_at_ms, last_used_at_ms, revoked_at_ms",
        )
        .bind(candidate_id)
        .bind(display_name)
        .bind(ssh_public_key)
        .bind(fingerprint)
        .bind(now_ms)
        .fetch_one(&mut *transaction)
        .await?;
        if device.revoked_at_ms.is_some() {
            return Err(StoreError::DeviceRevoked);
        }

        sqlx::query(
            "INSERT INTO device_host_grants \
             (device_id, host_id, created_at_ms, revoked_at_ms) VALUES (?, ?, ?, NULL) \
             ON CONFLICT(device_id, host_id) DO UPDATE SET revoked_at_ms = NULL",
        )
        .bind(&device.id)
        .bind(&host_id)
        .bind(now_ms)
        .execute(&mut *transaction)
        .await?;

        insert_audit(
            &mut transaction,
            now_ms,
            &AuditEvent {
                actor_type: "device".into(),
                actor_id: Some(device.id.clone()),
                action: "device.paired".into(),
                target_type: Some("host".into()),
                target_id: Some(host_id),
                outcome: "success".into(),
                bytes_in: 0,
                bytes_out: 0,
            },
        )
        .await?;
        transaction.commit().await?;
        Ok(device)
    }

    pub async fn append_audit(&self, event: AuditEvent) -> Result<(), StoreError> {
        let now_ms = system_time_ms(SystemTime::now())?;
        let mut transaction = self.pool.begin().await?;
        insert_audit(&mut transaction, now_ms, &event).await?;
        transaction.commit().await?;
        Ok(())
    }

    pub async fn list_audit_events(&self) -> Result<Vec<StoredAuditEvent>, StoreError> {
        Ok(sqlx::query_as::<_, StoredAuditEvent>(
            "SELECT id, occurred_at_ms, actor_type, actor_id, action, target_type, target_id, \
                    outcome, bytes_in, bytes_out \
             FROM audit_events ORDER BY id",
        )
        .fetch_all(&self.pool)
        .await?)
    }

    pub async fn is_ready(&self) -> bool {
        sqlx::query_scalar::<_, i64>("SELECT 1")
            .fetch_one(&self.pool)
            .await
            .is_ok()
    }

    pub async fn audit_column_names(&self) -> Result<Vec<String>, StoreError> {
        let rows = sqlx::query("PRAGMA table_info(audit_events)")
            .fetch_all(&self.pool)
            .await?;
        rows.into_iter()
            .map(|row| row.try_get("name").map_err(StoreError::from))
            .collect()
    }
}

async fn insert_audit(
    transaction: &mut Transaction<'_, Sqlite>,
    occurred_at_ms: i64,
    event: &AuditEvent,
) -> Result<(), StoreError> {
    sqlx::query(
        "INSERT INTO audit_events \
         (occurred_at_ms, actor_type, actor_id, action, target_type, target_id, outcome, bytes_in, bytes_out) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(occurred_at_ms)
    .bind(&event.actor_type)
    .bind(&event.actor_id)
    .bind(&event.action)
    .bind(&event.target_type)
    .bind(&event.target_id)
    .bind(&event.outcome)
    .bind(event.bytes_in)
    .bind(event.bytes_out)
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

fn opaque_id(prefix: &str) -> String {
    format!("{prefix}_{}", Uuid::new_v4().simple())
}

fn fingerprint(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(bytes))
}

fn system_time_ms(time: SystemTime) -> Result<i64, StoreError> {
    let millis = time
        .duration_since(UNIX_EPOCH)
        .map_err(|_| StoreError::InvalidTimestamp)?
        .as_millis();
    i64::try_from(millis).map_err(|_| StoreError::InvalidTimestamp)
}
