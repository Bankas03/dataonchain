CREATE TABLE `wallet_sweeps` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`from_wallet_id` text NOT NULL,
	`to_wallet_id` text NOT NULL,
	`to_address` text NOT NULL,
	`token` text NOT NULL,
	`amount_micro` integer NOT NULL,
	`open_key` text,
	`circle_transaction_id` text,
	`tx_hash` text,
	`status` text DEFAULT 'PENDING' NOT NULL,
	`last_error` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`from_wallet_id`) REFERENCES `wallets`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`to_wallet_id`) REFERENCES `wallets`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `wallet_sweeps_open_key_unique` ON `wallet_sweeps` (`open_key`);--> statement-breakpoint
CREATE UNIQUE INDEX `wallet_sweeps_circle_transaction_id_unique` ON `wallet_sweeps` (`circle_transaction_id`);--> statement-breakpoint
CREATE UNIQUE INDEX `wallet_sweeps_tx_hash_unique` ON `wallet_sweeps` (`tx_hash`);--> statement-breakpoint
CREATE INDEX `wallet_sweeps_status_idx` ON `wallet_sweeps` (`status`);--> statement-breakpoint
DROP INDEX `wallets_user_chain_idx`;--> statement-breakpoint
ALTER TABLE `wallets` ADD `account_type` text DEFAULT 'EOA' NOT NULL;--> statement-breakpoint
ALTER TABLE `wallets` ADD `retired_at` integer;--> statement-breakpoint
ALTER TABLE `wallets` ADD `checked_at` integer;--> statement-breakpoint
CREATE UNIQUE INDEX `wallets_user_chain_type_idx` ON `wallets` (`user_id`,`blockchain`,`account_type`);