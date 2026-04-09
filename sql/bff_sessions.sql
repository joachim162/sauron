/* bff_sessions table creation
 *
 * $Id:$
 */

/** This table contains server-side sessions for browser-based (BFF) auth.
    Used for email/password and OIDC authentication flows.
    Session tokens are stored as SHA-256 hashes (never plain text). **/

CREATE TABLE bff_sessions (
    token_hash   TEXT NOT NULL PRIMARY KEY, /* SHA-256 hash of session token */
    user_id      INT4 NOT NULL REFERENCES users(id) ON DELETE CASCADE, /* ptr to users.id */
    auth_method  TEXT NOT NULL DEFAULT 'password', /* 'password' or 'oidc' */
    created_at   INT4 DEFAULT 0, /* creation timestamp (Unix epoch) */
    last_used     INT4 DEFAULT 0, /* last usage timestamp (Unix epoch) */
    last_ip      TEXT, /* IP address of last use */
    expires_at   INT4 NOT NULL /* expiration timestamp (Unix epoch) */

) INHERITS(common_fields);

CREATE INDEX bff_sessions_user_id_index ON bff_sessions (user_id);
CREATE INDEX bff_sessions_expires_index ON bff_sessions (expires_at);
