CREATE TABLE `sends` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`wallet_address` text NOT NULL,
	`token` text NOT NULL,
	`amount` text NOT NULL,
	`to_address` text NOT NULL,
	`status` text DEFAULT 'AWAITING_CODE' NOT NULL,
	`code_hash` text,
	`code_expires_at` integer,
	`code_attempts` integer DEFAULT 0 NOT NULL,
	`circle_transaction_id` text,
	`tx_hash` text,
	`error` text,
	`open_key` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `sends_circle_transaction_id_unique` ON `sends` (`circle_transaction_id`);--> statement-breakpoint
CREATE UNIQUE INDEX `sends_open_key_unique` ON `sends` (`open_key`);--> statement-breakpoint
CREATE INDEX `sends_user_idx` ON `sends` (`user_id`);--> statement-breakpoint
CREATE INDEX `sends_status_idx` ON `sends` (`status`);