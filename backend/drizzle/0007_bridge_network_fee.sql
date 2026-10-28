ALTER TABLE `bridge_transfers` ADD `network_fee_micro` integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE `bridge_transfers` ADD `network_fee_status` text;--> statement-breakpoint
ALTER TABLE `bridge_transfers` ADD `network_fee_tx_id` text;--> statement-breakpoint
ALTER TABLE `bridge_transfers` ADD `network_fee_tx_hash` text;