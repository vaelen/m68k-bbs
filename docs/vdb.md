# Vaelen's Database Design Document

Vaelen's Database (vDB) is a a simple database in the style of database systems commonly used in the 80s and 90s. It is designed to be used in retrocomputing projects where CPU and memory resources are limited. Target systems include DOS, MacOS 6/7/8/9, Linux, and UNIX. It is written in ANSI C for maximum portability.

It's main features include:

1. Data stored in fixed-size blocks (called pages) for efficient random access. 
  - Empty blocks can be reused by future inserts. 
  - Records can use multiple adjacent pages if needed.
2. All changes are first written to a journal file before being written to the database. 
  - Reduces the likelihood of data corruption due to power outage or other system failure.
3. Indexes that speed up searches. 
  - Indexes are stored as B-Trees. 
  - A (required) primary index maps record IDs to physical page numbers. 
  - Additional (optional) indexes use a hash function to map strings to record IDs.
4. Page sizes are set to 512 bytes for more efficient disk access on older computers.
5. Deletion of data only marks the page as empty but does not clean up the data.
  - The database file is regularly compacted, a form of de-fragmentation that relocates active records into free pages to reduce the total size of the data files on disk.

## Data File Format

VDB data files are binary files organized into fixed-size 512-byte pages. This page-based architecture allows for both random access of specific records and easy reuse of freed space when records are removed. The 512-byte page size matches the BTree module's page size and is optimal for retro system disk I/O.

**Note: All multi-byte values are stored in little-endian byte order.** The library handles endian conversion automatically via macros in `vdbutil.h`, so database files are portable across big-endian and little-endian systems. All on-disk structures use explicit byte-by-byte serialization to avoid compiler alignment and padding differences.

### Files

Each database is actually comprised of a number of files. Let's look at the `Users` database as an example:
- USERS.DAT - The actual data is stored here (includes header in first page)
- USERS.IDX - Primary index mapping Record ID → Page Number (B-Tree)
- USERS.I00 - Secondary index 00 (e.g., username → Record ID)
- USERS.I01 - Secondary index 01 (e.g., email → Record ID)
- USERS.JNL - Journal file for transaction recovery

**Index Architecture**:
- The `.IDX` file is the primary index that maps Record IDs to physical Page Numbers
- All secondary indexes (`.I??` files) map field values to Record IDs
- This indirection allows records to move between pages without updating secondary indexes
- Only the primary `.IDX` index needs updating when a record's physical location changes

### Database Header (Pages 0-1 of .DAT file)

The database header spans the first two pages of the `.DAT` file. Page 0 contains metadata and index definitions, page 1 contains the free page list.

#### Page 0: DBHeader + Index List

**Header (32 bytes):**
| Name            | Type                          | Notes                                      |
| --------------- | ----------------------------- | ------------------------------------------ |
| signature       | char[4]                       | "VDB" + '\0' for file type validation      |
| version         | uint16                        | Format version (currently 1)               |
| page_size       | uint16                        | Size of each page in bytes (always 512)    |
| record_size     | uint16                        | Size of each record in bytes (1-130050)    |
| record_count    | int32                         | Total number of active records             |
| next_record_id  | int32                         | Next available Record ID                   |
| last_compacted  | int32                         | Timestamp of last compaction operation     |
| journal_pending | bool                          | true if journal needs replay on open       |
| index_count     | byte                          | Number of secondary indexes (0-15)         |
| reserved        | byte[8]                       | Padding to 32 bytes                        |

**Index List (480 bytes):**
| Name            | Type                          | Notes                                      |
| --------------- | ----------------------------- | ------------------------------------------ |
| indexes         | DBIndexInfo[15]               | Secondary index definitions (15 × 32 = 480)|

**Total page 0 size:** 32 + 480 = 512 bytes

#### Page 1: DBFreeList

| Name              | Type                          | Notes                                      |
| ----------------- | ----------------------------- | ------------------------------------------ |
| free_page_count   | uint16 (2 bytes)              | Total count of free pages in database      |
| free_page_list_len| uint16 (2 bytes)              | Number of entries in free_pages array (0-127)|
| free_pages        | int32[127]                    | Page numbers of empty pages (508 bytes)    |

**DBIndexInfo** (in page 0, after header):
| Name          | Type           | Notes                                           |
| ------------- | -------------- | ----------------------------------------------- |
| field_name    | char[30]       | The name of the field being indexed (30 bytes)  |
| index_type    | byte           | 0 = IT_ID (int32), 1 = IT_STRING (char[64])    |
| index_number  | byte           | Maps to one of the `I??` files (00-14)          |

**DBIndexInfo Size**: 30 bytes (field_name) + 1 byte (index_type) + 1 byte (index_number) = 32 bytes exactly

**Page 0 Layout**: 32 bytes (header) + 480 bytes (15 indexes × 32 bytes) = 512 bytes

**Index Type Values**:
- **0 (IT_ID)**: Index on an int32 field
- **1 (IT_STRING)**: Index on a char[64] field

**signature**: Used to verify file format. Always "VDB" followed by null terminator.

**version**: Format version number. Current version is 1. Future incompatible changes increment this.

**record_count**: Tracks active records. Updated on add/delete operations.

**next_record_id**: Auto-incrementing counter for assigning new Record IDs. Never decreases.

**page_size**: Always 512 bytes. This constant size matches the BTree module and simplifies disk I/O.

**record_size**: Size of each record in bytes. All records in this database are the same size. This determines how many pages each record occupies:
- **pages_per_record** = ceiling(record_size / 506)
- Maximum: 65535 bytes (limited by uint16), which is ~130 pages
- Examples: 100 byte record = 1 page, 1000 byte record = 2 pages

**Compaction**: The process of removing empty pages and rebuilding indexes to reclaim disk space. The `last_compacted` field tracks when this was last done.

**journal_pending**: Set to true when a transaction begins, false when committed. If true on database open, the journal must be replayed to complete interrupted operations.

**index_count**: Number of active secondary indexes (0-15). Maximum 15 indexes supported.

**reserved**: 8 bytes of padding to bring header to exactly 32 bytes.

**free_page_count** (in DBFreeList, page 1): Total count of all free pages in the database (maximum 65535). This counter is incremented when a page is deleted and decremented when a page is allocated. If this value is 0, allocate a new page at end of file. If this value is > 0 but `free_page_list_len = 0`, call `UpdateFreePages` to repopulate the `free_pages` array.

**free_page_list_len** (in DBFreeList, page 1): Number of valid entries in the `free_pages` array. Maximum 127. The array acts as a stack (LIFO) - new entries are added at index `free_page_list_len`, and pages are allocated by decrementing `free_page_list_len`.

**free_pages** (page 1): Array of up to 127 page numbers that are known to be empty. This provides O(1) free page lookup. When the array is full and more pages are deleted, `free_page_count` continues to increment but the page numbers are not added to the array. When `free_pages` is empty but `free_page_count > 0`, `UpdateFreePages` is called to scan the database and refill the array.

**indexes** (page 0, bytes 32-511): Array of 15 index definitions. Only the first `index_count` entries are valid. Each index has a unique `index_number` (0-14) that maps to an `.I??` file.

### Data Page Layout

The `.DAT` file contains a series of pages of type `DBPage` stored in fixed 512-byte format. Pages are numbered sequentially starting from 0. Pages 0-1 contain the database header (with index list) and free list. Data pages start at page 2.

Records may span multiple consecutive pages depending on `record_size`:
- **pages_per_record** = ceiling(record_size / 506)
- Records are stored in consecutive page runs
- All pages in a multi-page record share the same Record ID
- Only the first page has status = PS_ACTIVE, additional pages have status = PS_CONTINUATION

| Name   | Type                   | Notes                                    |
| ------ | ---------------------- | ---------------------------------------- |
| id     | int32 (4 bytes)        | Unique record identifier                 |
| status | byte (1 byte)          | 0 = Empty, 1 = Active, 2 = Continuation  |
| data   | byte[506]              | Actual record data (506 bytes per page)  |

**Page Size Calculation**:
- Page size: 512 bytes (constant)
- Overhead: 4 bytes (id) + 1 byte (status) + 1 byte (reserved) = 6 bytes
- Data size: 512 - 6 = 506 bytes available for record data per page

**Free Space Management**:
- When a record is deleted (spanning pages_per_record pages):
  - Set all pages `status` to PS_EMPTY
  - Increment `free_page_count` by pages_per_record
  - Add first page number to free list if room (subsequent pages can be calculated)
- When adding a record:
  - Calculate required pages: `pages_needed = CalculatePagesNeeded(record_size)`
  - If `free_page_count < pages_needed`: Append new pages at end of file
  - Else if `free_page_list_len > 0`:
    - Search free list for consecutive run of pages_needed pages
    - Or append to end if no suitable run found
  - Else: Call `UpdateFreePages` to scan and refill array
  - Mark first page status = PS_ACTIVE, additional pages status = PS_CONTINUATION
  - Decrement `free_page_count` by pages_needed

### Primary Index (.IDX file)

The `.IDX` file is a B-Tree index (as defined by the `btree` module) that maps Record IDs to Page Numbers.

**Index Structure**:
- **Keys**: Record IDs (int32 values from `DBPage.id`)
- **Values**: Page Numbers (physical page number of the first page where record starts)
- **Purpose**: Translates logical Record IDs to physical page locations

For multi-page records, the index points to the first page only. Subsequent pages are at consecutive positions (pageNum+1, pageNum+2, etc.).

This primary index is updated whenever:
- A record is added (insert RecordID → FirstPageNum mapping)
- A record is moved to a new location during compaction (update RecordID mapping)
- A record is deleted (remove RecordID from index)

### Secondary Indexes (.I?? files)

The `.I??` files contain B-Tree indexes for specific fields. The `??` in the extension should be replaced by the `index_number` value formatted as a 2-digit decimal. For example, `USERS.I00` or `USERS.I01`.

**Index Structure**:
- **Keys**: Field values (generated based on index_type)
- **Values**: Record IDs (NOT block IDs)
- **Purpose**: Look up records by field values

**Index Key Generation**:
- `IT_ID` type indexes: Use the field value directly as the B-Tree key
- `IT_STRING` type indexes: Use the `GenerateIndexKey()` function to generate a CRC16-based key from the string

**Index Values**: The B-Tree values are Record IDs. To retrieve the actual record, perform a second lookup in the primary `.IDX` index to get the Page Number.

## Journal File Structure

The journal file (`<database>.jnl`) contains pending operations that have not yet been committed. Each journal entry is a fixed-size record that describes an operation to be performed on the database.

### DBJournalEntry

| Name      | Type                   | Notes                                           |
| --------- | ---------------------- | ----------------------------------------------- |
| operation | byte                   | 0 = None/Empty, 1 = Update, 2 = Delete, 3 = Add |
| page_num  | int32 (4 bytes)        | Page being modified, -1 for Add operations      |
| record_id | int32 (4 bytes)        | Record ID for verification                      |
| data      | byte[507]              | New record data (for Update and Add)            |
| checksum  | uint16 (2 bytes)       | CRC16 of operation + page_num + record_id + data|

**Journal Entry Size**: 1 + 4 + 4 + 507 + 2 = 518 bytes

**Operation Types**:
- **0 (None/Empty)**: Unused journal entry
- **1 (Update)**: Update existing page at PageNum with new Data
- **2 (Delete)**: Mark page at PageNum as Empty
- **3 (Add)**: Add new record with Data (PageNum is -1, actual page assigned during replay)

**Checksum**: The CRC16 checksum ensures journal entry integrity. Corrupted entries are skipped during replay.

### Example Usage: Find a User by ID (Record ID)

At program start, the program reads the database header from pages 0-1 of the `.DAT` file (header with index list, and free list).

To find a User by their Record ID, the program:

1. **Opens the primary index**: Opens `USERS.IDX` using the BTree module
   ```c
   BTree idx_tree;
   OpenBTree(&idx_tree, "USERS.IDX");
   ```

2. **Finds the page number**: Calls `FindInIndex(&idx_tree, record_id, values, max_values, &count)` where `record_id` is the Record ID to search for
   - The `values` array will contain the physical page number of the first page

3. **Reads the data pages**:
   - Calculate pages needed: `pages_needed = CalculatePagesNeeded(db.header.record_size)`
   - For each page i from 0 to pages_needed-1:
     - Seeks to position `((page_num + i) * 512)` in `USERS.DAT`
     - Reads the `DBPage` struct (512 bytes)
     - Verifies `id == record_id`
     - First page: verify `status == PS_ACTIVE`
     - Additional pages: verify `status == PS_CONTINUATION`
     - Append `data` to record buffer
   - Returns the assembled record data to the caller

4. **Closes the index**: `CloseBTree(&idx_tree)`

### Example Usage: Find a User by Username

Finding by a secondary index requires two lookups: secondary index → Record ID, then primary index → Page Number.

1. **Looks up the index**: Search through the index list (page 0, bytes 32-511) for `field_name == "Username"`
   - Example: `{field_name: "Username", index_type: IT_STRING, index_number: 0}`

2. **Opens the secondary index file**: Opens `USERS.I00`
   ```c
   BTree name_tree;
   OpenBTree(&name_tree, "USERS.I00");
   ```

3. **Generates string key**: `key = GenerateIndexKey(IT_STRING, (const byte *)"alice")`
   - This is case-insensitive, so "alice", "Alice", "ALICE" all produce the same key

4. **Finds the Record ID**: `FindInIndex(&name_tree, key, record_ids, max_values, &count)`
   - The `record_ids` array contains Record IDs (may be multiple due to hash collisions)

5. **Lookup Page Number**: For each Record ID:
   - Open primary index: `OpenBTree(&idx_tree, "USERS.IDX")`
   - Find page: `FindInIndex(&idx_tree, record_id, page_nums, max_values, &count)`
   - Read record from .DAT file (may span multiple consecutive pages)
   - Verify username matches (handle CRC16 hash collisions)
   - Close primary index

6. **Closes the secondary index**: `CloseBTree(&name_tree)`

### Example Usage: Adding a New Record

1. **Assign Record ID**: Use `header.next_record_id` and increment it

2. **Calculate pages needed**: `pages_needed = CalculatePagesNeeded(header.record_size)`

3. **Find free pages**:
   - If `free_list.free_page_count < pages_needed`: Append new pages at end of file
   - Else if `free_list.free_page_list_len > 0`:
     - Search free list for consecutive run of pages_needed pages
     - If found: use those pages and remove from free list
     - If not found: append new pages at end of file
   - Else (count > 0 but list empty):
     - Call `UpdateFreePages` to scan database and refill `free_pages` array
     - Then search for consecutive run

4. **Write data across pages**:
   ```c
   int offset = 0;
   for (i = 0; i < pages_needed; i++) {
       page.id = new_record_id;
       page.status = (i == 0) ? PS_ACTIVE : PS_CONTINUATION;

       copy_len = (DB_PAGE_DATA_SIZE < record_size - offset)
                  ? DB_PAGE_DATA_SIZE : record_size - offset;
       memcpy(page.data, &user_data[offset], copy_len);
       /* Write to .DAT at (first_page_num + i) * DB_PAGE_SIZE */
       offset += DB_PAGE_DATA_SIZE;
   }
   ```

5. **Update primary index**:
   - Open `USERS.IDX`
   - Insert mapping: `InsertIntoIndex(&idx_tree, new_record_id, first_page_num)`
   - Note: Only the first page number is stored

6. **Update all secondary indexes**:
   - For username index: `InsertIntoIndex(&name_tree, GenerateIndexKey(IT_STRING, username), new_record_id)`
   - For email index: `InsertIntoIndex(&email_tree, GenerateIndexKey(IT_STRING, email), new_record_id)`
   - Note: Secondary indexes store Record IDs, not Page Numbers

7. **Update header and free list**:
   - Increment `header.record_count`
   - Increment `header.next_record_id`
   - Decrement `free_list.free_page_count` by pages_needed
   - Write header back to page 0
   - Write free list back to page 1 (if modified)

### Example Usage: Deleting a Record

1. **Find the record**: Use primary index to get Record ID → First Page Number

2. **Calculate pages to delete**: `pages_needed = CalculatePagesNeeded(db.header.record_size)`

3. **Mark all pages as empty**:
   ```c
   for (i = 0; i < pages_needed; i++) {
       page.status = PS_EMPTY;
       /* Write updated page at (first_page_num + i) back to .DAT */
   }
   ```

4. **Update primary index**:
   - `DeleteFromIndex(&idx_tree, record_id, record_id)` - Remove Record ID from primary index

5. **Update secondary indexes**: Remove from all secondary indexes
   - `DeleteFromIndex(&name_tree, GenerateIndexKey(IT_STRING, username), record_id)`
   - `DeleteFromIndex(&email_tree, GenerateIndexKey(IT_STRING, email), record_id)`

6. **Add to free list**:
   - Increment `free_list.free_page_count` by pages_needed
   - If `free_list.free_page_list_len < DB_MAX_FREE_PAGES`:
     - Add first page number to `free_pages[free_page_list_len]`
     - Increment `free_page_list_len`
     - Note: Only store first page; consecutive pages can be calculated
   - Else: Page numbers not added to array, but count still incremented

7. **Update header and free list**:
   - Decrement `header.record_count`
   - Write header back to page 0
   - Write free list back to page 1

8. **Compaction**: Eventually run compaction to consolidate pages and rebuild free list accurately

### Example Usage: Updating a Record

**Non-indexed field changes**:
- Simply overwrite the data in the existing pages (all pages_per_record pages)
- No index updates needed

**Indexed field changes** (e.g., username change):
1. **Delete old secondary index entry**: `DeleteFromIndex(&name_tree, GenerateIndexKey(IT_STRING, old_username), record_id)`
2. **Update the data pages**: Write new data to existing pages
3. **Insert new secondary index entry**: `InsertIntoIndex(&name_tree, GenerateIndexKey(IT_STRING, new_username), record_id)`
4. **Primary index unchanged**: Record ID stays the same, so primary index is not modified

**Moving a record to a new location** (during compaction):
1. **Write data to new pages**: Copy record to new physical location (pages_per_record consecutive pages)
2. **Update primary index**: Change mapping from `record_id → old_first_page_num` to `record_id → new_first_page_num`
3. **Mark old pages empty**: Set all old pages `status = PS_EMPTY`
4. **Secondary indexes unchanged**: They map to Record IDs, so no updates needed

## Transaction Protocol

The journal file provides crash recovery by recording operations before they are committed to the database. This ensures that partial writes due to power loss or crashes can be detected and completed.

### Write Operation Sequence

When updating, deleting, or adding records, follow this sequence:

1. **Append to journal**: Write a `DBJournalEntry` to the journal file with the operation details
   - For Update: operation=JO_UPDATE, page_num=target page, record_id=record ID, data=new data
   - For Delete: operation=JO_DELETE, page_num=target page, record_id=record ID
   - For Add: operation=JO_ADD, page_num=-1, record_id=new ID, data=new data

2. **Set pending flag**: Update `header.journal_pending = true` in page 0 of .DAT file

3. **Flush journal**: Ensure journal is written to disk (fsync/flush)

4. **Perform database update**: Execute the actual operation on the .DAT file

5. **Update indexes**: Modify all affected indexes (.I?? files)

6. **Clear pending flag**: Set `header.journal_pending = false` in page 0 of .DAT file

7. **Truncate journal**: Set journal file size to 0 bytes

**Multiple Operations**: For operations affecting multiple records (e.g., bulk updates), write all journal entries before setting the `journal_pending` flag. This creates a multi-operation transaction.

### Recovery on Database Open

When opening a database, check the `journal_pending` flag to determine if recovery is needed:

1. **Check flag**: Read `header.journal_pending` from page 0 of .DAT file

2. **If false**: Open database normally, no recovery needed

3. **If true**: Recovery is required:
   - Open journal file (.JNL)
   - For each journal entry:
     - Read entry and verify checksum using CRC16
     - If checksum valid, replay operation:
       - **JO_UPDATE (1)**: Write `data` to page `page_num` in .DAT file
       - **JO_DELETE (2)**: Set page `page_num` status to PS_EMPTY
       - **JO_ADD (3)**: Find first empty page (or append), write `data`
     - If checksum invalid, skip entry (corrupted)
   - Rebuild all indexes from .DAT file (safer than trusting partial index updates)
   - Set `header.journal_pending = false` in page 0 of .DAT file
   - Truncate journal file to 0 bytes

**Index Rebuild**: After crash recovery, always rebuild all indexes to ensure consistency. This is safer than attempting to replay partial index updates.

## Database Helper Methods

The `db` module should provide high-level helper functions to encapsulate these operations:

### Database Operations

**`bool OpenDatabase(const char *name, Database *db)`**
- Opens all database files (.DAT, .IDX, .I??)
- Loads metadata into memory
- Returns true on success

**`void CloseDatabase(Database *db)`**
- Closes all open files
- Writes any cached metadata

**`bool CreateDatabase(const char *name, uint16 record_size)`**
- Creates new .DAT and .IDX files
- Initializes with default values
- Returns true on success

### Record Operations

**`bool AddRecord(Database *db, const byte *data, int32 *record_id)`**
- Finds free block or allocates new one
- Writes data to .DAT file
- Updates all indexes
- Returns new record ID via pointer

**`bool FindRecordByID(Database *db, int32 id, byte *data)`**
- Uses ID index to locate block
- Reads and returns record data
- Returns true if found

**`bool FindRecordByString(Database *db, const char *field_name, const char *value, byte *data, int32 *record_id)`**
- Generates key using GenerateIndexKey()
- Uses appropriate string index
- Handles hash collisions
- Returns first matching record

**`bool UpdateRecord(Database *db, int32 id, const byte *data)`**
- Finds record by ID
- Overwrites data in existing block
- Updates indexes if indexed fields changed
- Returns true on success

**`bool DeleteRecord(Database *db, int32 id)`**
- Marks block as empty
- Removes from all indexes
- Returns true on success

### Index Operations

**`bool AddIndex(Database *db, const char *field_name, byte index_type)`**
- Creates new .I?? file
- Scans existing records to build index
- Updates index list in page 0 (increment `index_count`, add to `indexes` array)
- Returns true on success
- Maximum 15 indexes supported

**`bool RebuildIndex(Database *db, int16 index_number)`**
- Clears and rebuilds specified index
- Useful for corruption recovery
- Returns true on success

### Maintenance Operations

**`bool CompactDatabase(Database *db)`**
- Removes empty pages by moving active records
- Rebuilds all indexes
- Rebuilds free list with accurate `free_page_count` and `free_page_list_len`
- Updates last_compacted timestamp
- Returns true on success

**`bool UpdateFreePages(Database *db)`**
- Scans .DAT file for pages with `status == PS_EMPTY`
- Fills `free_pages` array with up to 127 empty page numbers
- Sets `free_page_list_len` to actual number found
- Sets `free_page_count` to actual total count of empty pages (for accuracy)
- Called automatically when `free_page_count > 0` but `free_page_list_len == 0`
- Returns true on success

**`bool ValidateDatabase(Database *db)`**
- Checks for corruption
- Validates indexes against data
- Returns true if database is valid

### Transaction Operations

**`bool BeginTransaction(Database *db)`**
- Sets `header.journal_pending = true`
- Prepares journal file for writing
- All subsequent operations will be journaled

**`bool CommitTransaction(Database *db)`**
- Sets `header.journal_pending = false`
- Truncates journal file to 0 bytes
- Finalizes all pending operations

**`bool RollbackTransaction(Database *db)`**
- Discards journal without applying
- Sets `header.journal_pending = false`
- Truncates journal file to 0 bytes
- Use when aborting an operation

**`bool ReplayJournal(Database *db)`**
- Reads and validates all journal entries
- Applies each operation to database
- Rebuilds all indexes
- Returns true on success
- Called automatically during `OpenDatabase` if `journal_pending` is true

## Data Types

```c
/* Index info - 32 bytes on disk */
typedef struct {
    char field_name[30];       /* Field name (30 bytes total) */
    byte index_type;           /* 0 = IT_ID, 1 = IT_STRING */
    byte index_number;         /* Index number 0-14 */
} DBIndexInfo;

/* Database header - 512 bytes (page 0) */
typedef struct {
    char        signature[4];  /* "VDB" + '\0' */
    uint16      version;       /* Format version (1) */
    uint16      page_size;     /* Size of each page (always 512) */
    uint16      record_size;   /* Size of each record in bytes */
    int32       record_count;  /* Total active records */
    int32       next_record_id;/* Next available Record ID */
    int32       last_compacted;/* Timestamp of last compaction */
    bool        journal_pending;/* true if journal needs replay */
    byte        index_count;   /* Number of secondary indexes (0-15) */
    byte        reserved[8];   /* Padding to 32 bytes */
    DBIndexInfo indexes[DB_MAX_INDEXES]; /* Secondary index definitions */
} DBHeader;

/* Free page list - 512 bytes (page 1) */
typedef struct {
    uint16 free_page_count;    /* Total count of free pages in DB */
    uint16 free_page_list_len; /* Number of entries in free_pages array */
    int32  free_pages[DB_MAX_FREE_PAGES]; /* Page numbers of empty pages */
} DBFreeList;

/* Database page - 512 bytes */
typedef struct {
    int32 id;                  /* Record ID */
    byte  status;              /* PS_EMPTY, PS_ACTIVE, or PS_CONTINUATION */
    byte  reserved;
    byte  data[DB_PAGE_DATA_SIZE]; /* 506 bytes */
} DBPage;

/* Journal entry - 518 bytes */
typedef struct {
    byte   operation;          /* JO_NONE, JO_UPDATE, JO_DELETE, or JO_ADD */
    int32  page_num;
    int32  record_id;
    byte   data[507];
    uint16 checksum;
} DBJournalEntry;

/* Database handle */
typedef struct {
    char       name[64];
    DBHeader   header;         /* Includes index list */
    DBFreeList free_list;
    FILE      *data_file;
    FILE      *journal_file;
    BTree     *primary_index;  /* .IDX - record_id → page_num */
    bool       is_open;
} Database;
```

## Performance Considerations

- **Primary index lookups**: O(log n) via B-Tree - fast
- **Secondary index lookups**: O(log n) + O(log n) = two B-Tree lookups (secondary → primary)
  - Trade-off: Slower reads for faster compaction and updates
- **Finding free pages**:
  - O(1) when `free_page_list_len > 0` (use array)
  - O(1) when `free_page_count == 0` (append new page)
  - O(n) when `free_page_count > 0` but `free_page_list_len == 0` (scan to refill array)
    - After scan, next 127 allocations are O(1)
  - `free_page_count` tracks total free pages for quick "are there any?" check
  - Array holds up to 127 page numbers for fast access
- **Multiple indexes**: Each insert/update/delete must update primary + all secondary indexes
- **Hash collisions**: GenerateIndexKey uses CRC16, so collisions are possible (1 in 65536)
  - Always verify string match after hash lookup
- **Journal overhead**: Each write operation requires:
  - One journal file append (518 bytes per entry, fsync)
  - One header update (set journal_pending to true in page 0)
  - Actual database modification
  - Second header update (clear flag)
  - Journal truncate
- **Recovery time**: Proportional to number of journal entries and total records (for index rebuild)
- **Batch operations**: Use multi-entry transactions to amortize journal overhead across multiple operations
- **Compaction advantage**: With indirect indexing, only primary index needs updating when moving records
  - Secondary indexes are unchanged since Record IDs don't change
- **Page alignment**: 512-byte pages align well with disk sector sizes on retro systems
- **Free list size**: 4 bytes header + 127 entries × 4 bytes = 512 bytes (fits in one 512-byte page perfectly)

## Future Enhancements

1. **Extended free list**: Linked list of free list pages for tracking more than 128 empty pages
2. **Multi-operation transactions**: Group related operations into atomic units
3. **Record-level checksums**: Detect data corruption in .DAT file
4. **Compression**: For large text fields
5. **Variable-length records**: More space-efficient storage
6. **Index caching**: Keep frequently-used index nodes in memory
7. **Incremental index updates**: During recovery, replay index changes from journal instead of full rebuild
