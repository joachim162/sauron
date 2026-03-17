# Legacy Global State
#legacy #perl #architecture #database

Sauron's legacy modules use a procedural approach to state management, which differs from modern object-oriented patterns.

## Database Connectivity
- **Initialization:** `Sauron::DB::db_connect()` is called once in [[API-Entry-Point]].
- **Storage:** The database handle is stored as a package variable (global state) within the `Sauron::DB` namespace.
- **Access:** Any module or controller that calls [[Sauron-Core-Integration]] functions will automatically use this shared connection.

## Implications for API Development
- You do **not** need to pass database handles around.
- The state is shared across all controllers within the same process.
- **Caution:** Because it is global, we must ensure `db_connect` is called successfully before any controller logic executes.

## Related
- [[Controller-Role]]
- [[Sauron-Core-Integration]]
