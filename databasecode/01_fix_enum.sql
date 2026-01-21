-- Run this script FIRST and ALONE to fix the Enum error.
-- PostgreSQL requires Enum value additions to be committed before they are used.
ALTER TYPE item_status ADD VALUE IF NOT EXISTS 'draft';
