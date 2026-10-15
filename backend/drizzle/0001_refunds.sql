CREATE TABLE `refunds` (
	`id` text PRIMARY KEY NOT NULL,
	`order_id` text NOT NULL,
	`payment_id` text NOT NULL,
	`to_address` text NOT NULL,
	`token` text NOT NULL,
	`blockchain` text NOT NULL,
	`amount_micro` integer NOT NULL,
	`attempt` integer DEFAULT 1 NOT NULL,
	`circle_transaction_id` text,
	`tx_hash` text,
	`status` text DEFAULT 'PENDING' NOT NULL,
	`last_error` text,
	`confirmed_at` integer,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`order_id`) REFERENCES `orders`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`payment_id`) REFERENCES `payments`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `refunds_order_id_unique` ON `refunds` (`order_id`);--> statement-breakpoint
CREATE UNIQUE INDEX `refunds_circle_transaction_id_unique` ON `refunds` (`circle_transaction_id`);--> statement-breakpoint
CREATE UNIQUE INDEX `refunds_tx_hash_unique` ON `refunds` (`tx_hash`);--> statement-breakpoint
CREATE INDEX `refunds_status_idx` ON `refunds` (`status`);