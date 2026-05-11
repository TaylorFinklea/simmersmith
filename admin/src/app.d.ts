// See https://kit.svelte.dev/docs/types#app for info about these
// declarations. The `Platform` interface mirrors the bindings declared
// in `wrangler.toml` so the SvelteKit `platform` arg is properly
// typed inside server-load functions.

declare global {
    namespace App {
        // interface Error {}
        // interface Locals {}
        // interface PageData {}
        // interface PageState {}
        interface Platform {
            env: {
                SIMMERSMITH_API_BASE?: string;
                SIMMERSMITH_ADMIN_TOKEN?: string;
                ASSETS?: Fetcher;
            };
            context: { waitUntil(promise: Promise<unknown>): void };
            caches?: CacheStorage & { default: Cache };
        }
    }
}

export {};
