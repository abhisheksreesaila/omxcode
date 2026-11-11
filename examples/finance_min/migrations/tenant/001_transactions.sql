-- up
CREATE TABLE IF NOT EXISTS transactions(id TEXT PRIMARY KEY, date TEXT NOT NULL, amount REAL NOT NULL, merchant TEXT, category TEXT, source TEXT NOT NULL DEFAULT 'manual', edited TEXT);
CREATE INDEX IF NOT EXISTS transactions_date ON transactions(date);
-- down
DROP TABLE transactions;
