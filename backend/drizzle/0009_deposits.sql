CREATE TABLE `deposits` (
	`id` text PRIMARY KEY NOT NULL,
	`circle_transaction_id` text NOT NULL,
	`user_id` text NOT NULL,
	`wallet_id` text NOT NULL,
	`chain` text NOT NULL,
	`token` text NOT NULL,
	`amount` text NOT NULL,
	`source_address` text,
	`tx_hash` text,
	`notified_at` integer,
	`received_at` integer NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`wallet_id`) REFERENCES `wallets`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `deposits_circle_transaction_id_unique` ON `deposits` (`circle_transaction_id`);--> statement-breakpoint
CREATE INDEX `deposits_user_idx` ON `deposits` (`user_id`,`received_at`);