CREATE TABLE `approved_destinations` (
	`id` text PRIMARY KEY NOT NULL,
	`label` text NOT NULL,
	`chain` text NOT NULL,
	`address` text NOT NULL,
	`active` integer DEFAULT true NOT NULL,
	`note` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `approved_destinations_chain_address_idx` ON `approved_destinations` (`chain`,`address`);--> statement-breakpoint
CREATE TABLE `bridge_events` (
	`id` text PRIMARY KEY NOT NULL,
	`transfer_id` text NOT NULL,
	`step` text NOT NULL,
	`chain` text,
	`tx_hash` text,
	`circle_transaction_id` text,
	`details` text,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`transfer_id`) REFERENCES `bridge_transfers`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `bridge_events_transfer_idx` ON `bridge_events` (`transfer_id`);--> statement-breakpoint
CREATE TABLE `bridge_transfers` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text,
	`direction` text NOT NULL,
	`source_chain` text NOT NULL,
	`destination_chain` text NOT NULL,
	`source_domain` integer NOT NULL,
	`destination_domain` integer NOT NULL,
	`depositor_wallet_id` text NOT NULL,
	`depositor_address` text NOT NULL,
	`recipient_address` text NOT NULL,
	`amount_micro` integer NOT NULL,
	`max_fee_micro` integer,
	`forwarding_fee_micro` integer,
	`salt` text NOT NULL,
	`burn_intent` text,
	`signature` text,
	`gateway_transfer_id` text,
	`mint_tx_hash` text,
	`status` text DEFAULT 'QUOTED' NOT NULL,
	`failure_reason` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `bridge_transfers_salt_unique` ON `bridge_transfers` (`salt`);--> statement-breakpoint
CREATE UNIQUE INDEX `bridge_transfers_gateway_transfer_id_unique` ON `bridge_transfers` (`gateway_transfer_id`);--> statement-breakpoint
CREATE INDEX `bridge_transfers_status_idx` ON `bridge_transfers` (`status`);--> statement-breakpoint
CREATE INDEX `bridge_transfers_user_idx` ON `bridge_transfers` (`user_id`);