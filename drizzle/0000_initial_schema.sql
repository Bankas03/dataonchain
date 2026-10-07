CREATE TABLE `accounts` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`account_id` text NOT NULL,
	`provider_id` text NOT NULL,
	`access_token` text,
	`refresh_token` text,
	`id_token` text,
	`access_token_expires_at` integer,
	`refresh_token_expires_at` integer,
	`scope` text,
	`password` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `accounts_user_id_idx` ON `accounts` (`user_id`);--> statement-breakpoint
CREATE TABLE `audit_logs` (
	`id` text PRIMARY KEY NOT NULL,
	`actor_type` text NOT NULL,
	`actor_id` text,
	`action` text NOT NULL,
	`target_type` text,
	`target_id` text,
	`details` text,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `audit_logs_target_idx` ON `audit_logs` (`target_type`,`target_id`);--> statement-breakpoint
CREATE TABLE `data_plans` (
	`id` text PRIMARY KEY NOT NULL,
	`provider` text NOT NULL,
	`service_type` text NOT NULL,
	`network` text NOT NULL,
	`plan_code` text NOT NULL,
	`name` text NOT NULL,
	`validity` text,
	`price_kobo` integer NOT NULL,
	`active` integer DEFAULT true NOT NULL,
	`synced_at` integer,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `data_plans_provider_code_idx` ON `data_plans` (`provider`,`network`,`plan_code`);--> statement-breakpoint
CREATE INDEX `data_plans_network_idx` ON `data_plans` (`network`,`active`);--> statement-breakpoint
CREATE TABLE `exchange_rates` (
	`id` text PRIMARY KEY NOT NULL,
	`source` text NOT NULL,
	`kobo_per_usdc` integer NOT NULL,
	`fetched_at` integer NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `exchange_rates_fetched_at_idx` ON `exchange_rates` (`fetched_at`);--> statement-breakpoint
CREATE TABLE `ledger_entries` (
	`id` text PRIMARY KEY NOT NULL,
	`journal_id` text NOT NULL,
	`account` text NOT NULL,
	`order_id` text,
	`currency` text NOT NULL,
	`debit` integer DEFAULT 0 NOT NULL,
	`credit` integer DEFAULT 0 NOT NULL,
	`memo` text,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`order_id`) REFERENCES `orders`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `ledger_entries_journal_idx` ON `ledger_entries` (`journal_id`);--> statement-breakpoint
CREATE INDEX `ledger_entries_account_idx` ON `ledger_entries` (`account`);--> statement-breakpoint
CREATE TABLE `orders` (
	`id` text PRIMARY KEY NOT NULL,
	`reference` text NOT NULL,
	`user_id` text NOT NULL,
	`service_type` text NOT NULL,
	`network` text NOT NULL,
	`plan_id` text,
	`phone` text NOT NULL,
	`ngn_amount_kobo` integer NOT NULL,
	`margin_kobo` integer DEFAULT 0 NOT NULL,
	`usdc_amount_micro` integer NOT NULL,
	`exchange_rate_id` text NOT NULL,
	`status` text DEFAULT 'QUOTED' NOT NULL,
	`quote_expires_at` integer NOT NULL,
	`failure_reason` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`plan_id`) REFERENCES `data_plans`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`exchange_rate_id`) REFERENCES `exchange_rates`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `orders_reference_unique` ON `orders` (`reference`);--> statement-breakpoint
CREATE INDEX `orders_user_id_idx` ON `orders` (`user_id`);--> statement-breakpoint
CREATE INDEX `orders_status_idx` ON `orders` (`status`);--> statement-breakpoint
CREATE TABLE `payments` (
	`id` text PRIMARY KEY NOT NULL,
	`order_id` text NOT NULL,
	`wallet_id` text,
	`circle_transaction_id` text,
	`tx_hash` text,
	`from_address` text,
	`to_address` text NOT NULL,
	`token` text DEFAULT 'USDC' NOT NULL,
	`blockchain` text NOT NULL,
	`amount_micro` integer NOT NULL,
	`status` text DEFAULT 'INITIATED' NOT NULL,
	`confirmed_at` integer,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`order_id`) REFERENCES `orders`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`wallet_id`) REFERENCES `wallets`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `payments_circle_transaction_id_unique` ON `payments` (`circle_transaction_id`);--> statement-breakpoint
CREATE UNIQUE INDEX `payments_tx_hash_unique` ON `payments` (`tx_hash`);--> statement-breakpoint
CREATE INDEX `payments_order_id_idx` ON `payments` (`order_id`);--> statement-breakpoint
CREATE INDEX `payments_status_idx` ON `payments` (`status`);--> statement-breakpoint
CREATE TABLE `sessions` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`token` text NOT NULL,
	`expires_at` integer NOT NULL,
	`ip_address` text,
	`user_agent` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `sessions_token_unique` ON `sessions` (`token`);--> statement-breakpoint
CREATE INDEX `sessions_user_id_idx` ON `sessions` (`user_id`);--> statement-breakpoint
CREATE TABLE `treasury_movements` (
	`id` text PRIMARY KEY NOT NULL,
	`type` text NOT NULL,
	`usdc_amount_micro` integer,
	`ngn_amount_kobo` integer,
	`kobo_per_usdc` integer,
	`reference` text,
	`note` text,
	`created_by` text,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`created_by`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE TABLE `users` (
	`id` text PRIMARY KEY NOT NULL,
	`name` text NOT NULL,
	`email` text NOT NULL,
	`email_verified` integer DEFAULT false NOT NULL,
	`image` text,
	`phone` text,
	`role` text DEFAULT 'user' NOT NULL,
	`status` text DEFAULT 'active' NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `users_email_unique` ON `users` (`email`);--> statement-breakpoint
CREATE TABLE `verifications` (
	`id` text PRIMARY KEY NOT NULL,
	`identifier` text NOT NULL,
	`value` text NOT NULL,
	`expires_at` integer NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `verifications_identifier_idx` ON `verifications` (`identifier`);--> statement-breakpoint
CREATE TABLE `vtu_transactions` (
	`id` text PRIMARY KEY NOT NULL,
	`order_id` text NOT NULL,
	`provider` text NOT NULL,
	`request_id` text NOT NULL,
	`provider_reference` text,
	`attempt` integer DEFAULT 1 NOT NULL,
	`status` text DEFAULT 'SENT' NOT NULL,
	`request_payload` text,
	`response_payload` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`order_id`) REFERENCES `orders`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `vtu_transactions_request_id_unique` ON `vtu_transactions` (`request_id`);--> statement-breakpoint
CREATE INDEX `vtu_transactions_order_id_idx` ON `vtu_transactions` (`order_id`);--> statement-breakpoint
CREATE INDEX `vtu_transactions_status_idx` ON `vtu_transactions` (`status`);--> statement-breakpoint
CREATE TABLE `wallets` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text,
	`purpose` text DEFAULT 'user' NOT NULL,
	`circle_wallet_id` text NOT NULL,
	`circle_wallet_set_id` text NOT NULL,
	`custody_type` text DEFAULT 'DEVELOPER' NOT NULL,
	`blockchain` text NOT NULL,
	`address` text NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `wallets_circle_wallet_id_unique` ON `wallets` (`circle_wallet_id`);--> statement-breakpoint
CREATE UNIQUE INDEX `wallets_user_chain_idx` ON `wallets` (`user_id`,`blockchain`);--> statement-breakpoint
CREATE INDEX `wallets_address_idx` ON `wallets` (`address`);--> statement-breakpoint
CREATE TABLE `webhook_events` (
	`id` text PRIMARY KEY NOT NULL,
	`source` text NOT NULL,
	`event_id` text NOT NULL,
	`type` text,
	`payload` text NOT NULL,
	`processed_at` integer,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `webhook_events_source_event_idx` ON `webhook_events` (`source`,`event_id`);