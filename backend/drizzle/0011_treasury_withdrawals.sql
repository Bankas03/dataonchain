CREATE TABLE `treasury_withdrawals` (
	`id` text PRIMARY KEY NOT NULL,
	`admin_id` text,
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
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `treasury_withdrawals_circle_transaction_id_unique` ON `treasury_withdrawals` (`circle_transaction_id`);--> statement-breakpoint
CREATE UNIQUE INDEX `treasury_withdrawals_open_key_unique` ON `treasury_withdrawals` (`open_key`);--> statement-breakpoint
CREATE INDEX `treasury_withdrawals_status_idx` ON `treasury_withdrawals` (`status`);