CREATE TABLE `admin_accounts` (
	`id` text PRIMARY KEY NOT NULL,
	`email` text NOT NULL,
	`password_hash` text,
	`failed_attempts` integer DEFAULT 0 NOT NULL,
	`locked_until` integer,
	`password_changed_at` integer,
	`last_login_at` integer,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `admin_accounts_email_unique` ON `admin_accounts` (`email`);--> statement-breakpoint
CREATE TABLE `admin_reset_tokens` (
	`id` text PRIMARY KEY NOT NULL,
	`account_id` text NOT NULL,
	`token_hash` text NOT NULL,
	`expires_at` integer NOT NULL,
	`used_at` integer,
	`ip_address` text,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`account_id`) REFERENCES `admin_accounts`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `admin_reset_tokens_token_hash_unique` ON `admin_reset_tokens` (`token_hash`);--> statement-breakpoint
CREATE INDEX `admin_reset_tokens_account_idx` ON `admin_reset_tokens` (`account_id`);--> statement-breakpoint
CREATE TABLE `admin_sessions` (
	`id` text PRIMARY KEY NOT NULL,
	`account_id` text NOT NULL,
	`token_hash` text NOT NULL,
	`stage` text DEFAULT 'code' NOT NULL,
	`code_hash` text,
	`code_attempts` integer DEFAULT 0 NOT NULL,
	`ip_address` text,
	`user_agent` text,
	`expires_at` integer NOT NULL,
	`last_seen_at` integer NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`account_id`) REFERENCES `admin_accounts`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `admin_sessions_token_hash_unique` ON `admin_sessions` (`token_hash`);--> statement-breakpoint
CREATE INDEX `admin_sessions_account_idx` ON `admin_sessions` (`account_id`);--> statement-breakpoint
CREATE TABLE `app_settings` (
	`key` text PRIMARY KEY NOT NULL,
	`value` text NOT NULL,
	`updated_at` integer NOT NULL
);
