-- collab update table.
-- If af_collab exists but is not partitioned, rebuild it as a partitioned table and keep data.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_class c WHERE c.relname = 'af_collab'
    ) THEN
        -- Fresh create
        CREATE TABLE af_collab (
            oid TEXT NOT NULL,
            blob BYTEA NOT NULL,
            len INTEGER,
            partition_key INTEGER NOT NULL,
            encrypt INTEGER DEFAULT 0,
            owner_uid BIGINT NOT NULL,
            deleted_at TIMESTAMP WITH TIME ZONE DEFAULT NULL,
            created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
            workspace_id UUID NOT NULL REFERENCES af_workspace(workspace_id) ON DELETE CASCADE,
            PRIMARY KEY (oid, partition_key)
        ) PARTITION BY LIST (partition_key);
    ELSIF NOT EXISTS (
        SELECT 1
        FROM pg_partitioned_table pt
        JOIN pg_class c ON c.oid = pt.partrelid
        WHERE c.relname = 'af_collab'
    ) THEN
        -- Exists but is not partitioned: recreate as partitioned and copy data.
        ALTER TABLE af_collab RENAME TO af_collab_legacy;
        CREATE TABLE af_collab (
            oid TEXT NOT NULL,
            blob BYTEA NOT NULL,
            len INTEGER,
            partition_key INTEGER NOT NULL,
            encrypt INTEGER DEFAULT 0,
            owner_uid BIGINT NOT NULL,
            deleted_at TIMESTAMP WITH TIME ZONE DEFAULT NULL,
            created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
            workspace_id UUID NOT NULL REFERENCES af_workspace(workspace_id) ON DELETE CASCADE,
            PRIMARY KEY (oid, partition_key)
        ) PARTITION BY LIST (partition_key);

        -- Copy data only if legacy has the required columns; otherwise skip with a notice to avoid failure.
        IF (
            SELECT COUNT(*) = 9 FROM information_schema.columns
            WHERE table_schema = 'public'
              AND table_name = 'af_collab_legacy'
              AND column_name IN ('oid','blob','len','partition_key','encrypt','owner_uid','deleted_at','created_at','workspace_id')
        ) THEN
            INSERT INTO af_collab (oid, blob, len, partition_key, encrypt, owner_uid, deleted_at, created_at, workspace_id)
            SELECT oid, blob, len, partition_key, encrypt, owner_uid, deleted_at, created_at, workspace_id
            FROM af_collab_legacy;
        ELSE
            RAISE NOTICE 'af_collab_legacy missing required columns; skipping data copy';
        END IF;

        -- Drop any foreign keys pointing to the legacy table before dropping it.
        PERFORM format('ALTER TABLE %s DROP CONSTRAINT %I', conrelid::regclass, conname)
        FROM pg_constraint
        WHERE confrelid = 'public.af_collab_legacy'::regclass;

        DROP TABLE af_collab_legacy;
    END IF;
END$$;

CREATE TABLE IF NOT EXISTS af_collab_document PARTITION OF af_collab FOR
VALUES IN (0);
CREATE TABLE IF NOT EXISTS af_collab_database PARTITION OF af_collab FOR
VALUES IN (1);
CREATE TABLE IF NOT EXISTS af_collab_w_database PARTITION OF af_collab FOR
VALUES IN (2);
CREATE TABLE IF NOT EXISTS af_collab_folder PARTITION OF af_collab FOR
VALUES IN (3);
CREATE TABLE IF NOT EXISTS af_collab_database_row PARTITION OF af_collab FOR
VALUES IN (4);
CREATE TABLE IF NOT EXISTS af_collab_user_awareness PARTITION OF af_collab FOR
VALUES IN (5);

CREATE TABLE IF NOT EXISTS af_collab_member (
    uid BIGINT REFERENCES af_user(uid) ON DELETE CASCADE,
    oid TEXT NOT NULL,
    permission_id INTEGER REFERENCES af_permissions(id) NOT NULL,
    PRIMARY KEY(uid, oid)
);

-- Listener
CREATE OR REPLACE FUNCTION notify_af_collab_member_change() RETURNS trigger AS $$
DECLARE
payload TEXT;
BEGIN
    payload := json_build_object(
            'old', row_to_json(OLD),
            'new', row_to_json(NEW),
            'action_type', TG_OP
            )::text;

    PERFORM pg_notify('af_collab_member_channel', payload);
    -- Return the new row state for INSERT/UPDATE, and the old state for DELETE.
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
ELSE
        RETURN NEW;
END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER af_collab_member_change_trigger
    AFTER INSERT OR UPDATE OR DELETE ON af_collab_member
    FOR EACH ROW EXECUTE FUNCTION notify_af_collab_member_change();

-- collab snapshot. It will be used to store the snapshots of the collab.
CREATE TABLE IF NOT EXISTS af_collab_snapshot (
    sid BIGSERIAL PRIMARY KEY,-- snapshot id
    oid TEXT NOT NULL,
    blob BYTEA NOT NULL,
    len INTEGER NOT NULL,
    encrypt INTEGER DEFAULT 0,
    deleted_at TIMESTAMP WITH TIME ZONE DEFAULT NULL,
    workspace_id UUID NOT NULL REFERENCES af_workspace(workspace_id) ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_af_collab_snapshot_oid ON af_collab_snapshot(oid);
