-- AlterTable
ALTER TABLE "StockMovement" ADD COLUMN IF NOT EXISTS "clientUuid" TEXT;

-- CreateIndex
CREATE INDEX IF NOT EXISTS "StockMovement_clientUuid_idx" ON "StockMovement"("clientUuid");

-- AlterTable
ALTER TABLE "SyncOperation" ADD COLUMN IF NOT EXISTS "error" TEXT;
