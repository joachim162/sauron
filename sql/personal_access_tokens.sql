/* personal_access_tokens table creation
 *
 * $Id:$
 */

/** This table stores Personal Access Tokens (PAT) for API authentication.
    Tokens are linked to existing users and inherit their permissions. **/

CREATE TABLE personal_access_tokens (
	id		SERIAL PRIMARY KEY, /* unique ID */
	user_id		INT4 NOT NULL REFERENCES users(id) ON DELETE CASCADE, /* ptr to users.id */
	token_hash	TEXT NOT NULL, /* SHA-256 hash of the token */
	name		TEXT NOT NULL, /* descriptive name (e.g., "SaltStack Automation") */
	created_at	INT4 DEFAULT 0, /* creation timestamp (Unix epoch) */
	expires_at	INT4 DEFAULT 0, /* expiration timestamp (0 = never expires) */
	last_used	INT4 DEFAULT 0, /* last usage timestamp (Unix epoch) */
	last_ip		TEXT, /* IP address of last use */

	CONSTRAINT	token_hash_key UNIQUE(token_hash)
) INHERITS(common_fields);

CREATE INDEX pat_user_id_index ON personal_access_tokens (user_id);
