ALTER TABLE `bridge_transfers` ADD `open_key` text;--> statement-breakpoint
CREATE UNIQUE INDEX `bridge_transfers_open_key_idx` ON `bridge_transfers` (`open_key`);