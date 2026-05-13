/**
 * Server-side fetcher into the SimmerSmith FastAPI backend.
 *
 * Reads SIMMERSMITH_ADMIN_TOKEN from the Worker's secret bindings and
 * SIMMERSMITH_API_BASE from the public vars block. The token never
 * crosses to the browser — every page does its data fetching in
 * `+page.server.ts` so the secret lives only on the Worker.
 *
 * Cloudflare Access is the outer auth gate at the hostname level;
 * once a request reaches us, it's already authenticated against the
 * Access allowlist. The admin token is the *backend's* gate so the
 * Worker can prove it's allowed to call admin endpoints.
 */

/**
 * SvelteKit's `platform` value is `Readonly<App.Platform> | undefined`
 * at the call site. The shape we need is `App.Platform` itself (defined
 * in `src/app.d.ts`) — readonly is fine.
 */
export type Platform = Readonly<App.Platform>;

export class AdminApiError extends Error {
    constructor(
        public readonly status: number,
        public readonly body: string,
        message?: string
    ) {
        super(message ?? `Backend ${status}`);
    }
}

function resolveBase(platform: Platform | undefined): string {
    const base = platform?.env?.SIMMERSMITH_API_BASE?.trim();
    if (!base) {
        throw new AdminApiError(500, '', 'SIMMERSMITH_API_BASE is not configured');
    }
    return base.replace(/\/$/, '');
}

function resolveToken(platform: Platform | undefined): string {
    const token = platform?.env?.SIMMERSMITH_ADMIN_TOKEN?.trim();
    if (!token) {
        throw new AdminApiError(500, '', 'SIMMERSMITH_ADMIN_TOKEN is not configured');
    }
    return token;
}

async function call<T>(
    platform: Platform | undefined,
    path: string,
    init: RequestInit = {}
): Promise<T> {
    const base = resolveBase(platform);
    const token = resolveToken(platform);
    const headers = new Headers(init.headers ?? {});
    headers.set('Authorization', `Bearer ${token}`);
    if (init.body && !headers.has('Content-Type')) {
        headers.set('Content-Type', 'application/json');
    }
    const response = await fetch(`${base}${path}`, { ...init, headers });
    if (!response.ok) {
        const body = await response.text();
        throw new AdminApiError(response.status, body);
    }
    return (await response.json()) as T;
}

export interface UsageSummary {
    period: string;
    totals: Record<string, number>;
    estimated_cost_usd: number;
    by_user: Array<{
        user_id: string;
        email: string;
        display_name: string;
        totals: Record<string, number>;
        total: number;
        estimated_cost_usd: number;
    }>;
}

export interface UsersResponse {
    period: string;
    users: Array<{
        user_id: string;
        email: string;
        display_name: string;
        created_at: string;
        monthly_usage: number;
        estimated_cost_usd: number;
        subscription_status: string;
        subscription_product: string;
        subscription_source: '' | 'apple' | 'admin';
    }>;
}

export interface SubscriptionPayload {
    status: string;
    product_id: string;
    source: 'apple' | 'admin';
    current_period_starts_at: string;
    current_period_ends_at: string;
    auto_renew: boolean;
    cancelled_at: string | null;
    admin_note: string | null;
    created_at: string;
    updated_at: string;
}

export interface PeriodUsage {
    period: string;
    totals: Record<string, number>;
    total: number;
    estimated_cost_usd: number;
}

export interface UserDetail {
    user: {
        id: string;
        email: string;
        display_name: string;
        created_at: string;
        has_apple_sign_in: boolean;
        has_google_sign_in: boolean;
    };
    subscription: SubscriptionPayload | null;
    usage: {
        this_period: PeriodUsage;
        previous_period: PeriodUsage;
    };
    inventory: {
        recipes: number;
        weeks: number;
        active_push_devices: number;
    };
}

export interface SettingsField<T> {
    value: T;
    default: T;
    overridden: boolean;
}

export interface AdminSettings {
    free_tier_limits: SettingsField<Record<string, number>>;
    ai_openai_model: SettingsField<string>;
    ai_anthropic_model: SettingsField<string>;
    trial_mode_enabled: SettingsField<boolean>;
    usage_cost_usd: SettingsField<Record<string, number>>;
}

export type SubscriptionAction =
    | { action: 'grant_pro'; until: string; note?: string; product_id?: string }
    | { action: 'revoke' };

export const adminApi = {
    usage: (platform: Platform | undefined, period?: string) =>
        call<UsageSummary>(platform, `/api/admin/usage${period ? `?period=${period}` : ''}`),
    users: (platform: Platform | undefined) => call<UsersResponse>(platform, '/api/admin/users'),
    user: (platform: Platform | undefined, userId: string) =>
        call<UserDetail>(platform, `/api/admin/users/${encodeURIComponent(userId)}`),
    subscriptionOverride: (
        platform: Platform | undefined,
        userId: string,
        body: SubscriptionAction
    ) =>
        call<{ subscription: SubscriptionPayload }>(
            platform,
            `/api/admin/users/${encodeURIComponent(userId)}/subscription`,
            { method: 'POST', body: JSON.stringify(body) }
        ),
    settings: (platform: Platform | undefined) => call<AdminSettings>(platform, '/api/admin/settings'),
    patchSettings: (
        platform: Platform | undefined,
        patch: Partial<{
            free_tier_limits: Record<string, number> | null;
            ai_openai_model: string | null;
            ai_anthropic_model: string | null;
            trial_mode_enabled: boolean | null;
            usage_cost_usd: Record<string, number> | null;
        }>
    ) =>
        call<AdminSettings>(platform, '/api/admin/settings', {
            method: 'PATCH',
            body: JSON.stringify(patch)
        })
};
