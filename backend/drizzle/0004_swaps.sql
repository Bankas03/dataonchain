CREATE TABLE `swaps` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`wallet_address` text NOT NULL,
	`token_in` text NOT NULL,
	`token_out` text NOT NULL,
	`amount_in` text NOT NULL,
	`estimated_out` text,
	`min_out` text,
	`amount_out` text,
	`fee_bps` integer NOT NULL,
	`slippage_bps` integer NOT NULL,
	`tx_hash` text,
	`status` text DEFAULT 'PENDING' NOT NULL,
	`error` text,
	`details` text,
	`open_key` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `swaps_open_key_unique` ON `swaps` (`open_key`);--> statement-breakpoint
CREATE INDEX `swaps_user_idx` ON `swaps` (`user_id`);--> statement-breakpoint
CREATE INDEX `swaps_status_idx` ON `swaps` (`status`);