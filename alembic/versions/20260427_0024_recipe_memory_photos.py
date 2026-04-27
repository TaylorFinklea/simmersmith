"""Add optional photo columns to recipe_memories (M15 Phase 2).

Each memory entry can carry one optional photo. Bytes are stored
inline on the same row, but the GET-list route uses an explicit
column-list select so listing memories never pulls 1 MB blobs.
The serve route at GET /api/recipes/{id}/memories/{memory_id}/photo
streams the bytes with ETag + immutable Cache-Control (mirrors the
M14 recipe_images route).

Revision ID: 20260427_0024
Revises: 20260427_0023
Create Date: 2026-04-27 14:00:00
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260427_0024"
down_revision = "20260427_0023"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("recipe_memories") as batch:
        batch.add_column(sa.Column("image_bytes", sa.LargeBinary(), nullable=True))
        batch.add_column(sa.Column("mime_type", sa.String(64), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("recipe_memories") as batch:
        batch.drop_column("mime_type")
        batch.drop_column("image_bytes")
