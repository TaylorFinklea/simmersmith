<script lang="ts">
    import type { PageData, ActionData } from './$types';

    let { data, form }: { data: PageData; form: ActionData } = $props();
    let detail = $derived(data);

    function shortDate(iso: string | null | undefined) {
        if (!iso) return '—';
        return new Date(iso).toISOString().slice(0, 10);
    }

    function money(n: number) {
        return `$${n.toFixed(4)}`;
    }

    // Default the date picker to +30 days from today so the operator
    // only types when they want a different window.
    function defaultUntil() {
        const d = new Date();
        d.setUTCDate(d.getUTCDate() + 30);
        return d.toISOString().slice(0, 10);
    }
</script>

<section>
    <a href="/users" class="text-sm text-ink-soft hover:text-ember">&larr; users</a>
    <h2 class="text-3xl italic mt-1 mb-1">
        {detail.user.email || detail.user.display_name || detail.user.id}
    </h2>
    <div class="hand-rule w-24 mb-6"></div>

    {#if form && 'ok' in form && form.ok}
        <div class="mb-6 p-3 rounded border border-success/40 bg-success/10 text-success">
            {form.message}
        </div>
    {/if}
    {#if form && 'error' in form && form.error}
        <div class="mb-6 p-3 rounded border border-destructive/40 bg-destructive/10 text-destructive">
            {form.error}
        </div>
    {/if}

    <!-- Profile -->
    <div class="bg-paper-alt border border-rule rounded p-5 mb-6">
        <h3 class="text-xl italic mb-3">Profile</h3>
        <dl class="grid grid-cols-[max-content_1fr] gap-x-6 gap-y-2 text-sm">
            <dt class="text-ink-soft">User ID</dt>
            <dd class="font-mono text-xs break-all">{detail.user.id}</dd>
            <dt class="text-ink-soft">Email</dt>
            <dd>{detail.user.email || '(none)'}</dd>
            <dt class="text-ink-soft">Display name</dt>
            <dd>{detail.user.display_name || '—'}</dd>
            <dt class="text-ink-soft">Joined</dt>
            <dd class="font-mono">{shortDate(detail.user.created_at)}</dd>
            <dt class="text-ink-soft">Sign-in</dt>
            <dd>
                {#if detail.user.has_apple_sign_in}<span class="text-xs px-2 py-0.5 rounded bg-paper-alt border border-rule mr-1">Apple</span>{/if}
                {#if detail.user.has_google_sign_in}<span class="text-xs px-2 py-0.5 rounded bg-paper-alt border border-rule">Google</span>{/if}
                {#if !detail.user.has_apple_sign_in && !detail.user.has_google_sign_in}<span class="text-ink-faint">—</span>{/if}
            </dd>
        </dl>
    </div>

    <!-- Subscription + override -->
    <div class="bg-paper-alt border border-rule rounded p-5 mb-6">
        <div class="flex items-baseline justify-between mb-3">
            <h3 class="text-xl italic">Subscription</h3>
            {#if detail.subscription}
                <span
                    class="text-xs px-2 py-0.5 rounded {detail.subscription.source === 'admin'
                        ? 'bg-ember/20 text-ember'
                        : 'bg-paper border border-rule text-ink-soft'}"
                >
                    {detail.subscription.source}
                </span>
            {/if}
        </div>

        {#if detail.subscription}
            <dl class="grid grid-cols-[max-content_1fr] gap-x-6 gap-y-2 text-sm mb-4">
                <dt class="text-ink-soft">Status</dt>
                <dd class="font-mono">{detail.subscription.status}</dd>
                <dt class="text-ink-soft">Product</dt>
                <dd class="font-mono">{detail.subscription.product_id}</dd>
                <dt class="text-ink-soft">Period</dt>
                <dd class="font-mono">
                    {shortDate(detail.subscription.current_period_starts_at)}
                    → {shortDate(detail.subscription.current_period_ends_at)}
                </dd>
                {#if detail.subscription.cancelled_at}
                    <dt class="text-ink-soft">Cancelled</dt>
                    <dd class="font-mono">{shortDate(detail.subscription.cancelled_at)}</dd>
                {/if}
                {#if detail.subscription.admin_note}
                    <dt class="text-ink-soft">Note</dt>
                    <dd>{detail.subscription.admin_note}</dd>
                {/if}
            </dl>
        {:else}
            <p class="text-sm text-ink-soft mb-4">
                Free tier. No subscription row.
            </p>
        {/if}

        <form method="post" action="?/grant_pro" class="space-y-3 border-t border-rule pt-4">
            <h4 class="text-sm font-medium">
                {detail.subscription?.source === 'admin' ? 'Extend admin grant' : 'Grant Pro'}
            </h4>
            <div class="flex flex-wrap items-end gap-3">
                <div>
                    <label for="until" class="block text-xs text-ink-soft mb-1">Expires</label>
                    <input
                        id="until"
                        name="until"
                        type="date"
                        value={shortDate(detail.subscription?.current_period_ends_at) === '—' ? defaultUntil() : shortDate(detail.subscription?.current_period_ends_at)}
                        class="bg-paper border border-rule rounded px-2 py-1 font-mono text-sm"
                        required
                    />
                </div>
                <div class="flex-1 min-w-[200px]">
                    <label for="note" class="block text-xs text-ink-soft mb-1">Note (optional)</label>
                    <input
                        id="note"
                        name="note"
                        type="text"
                        value={detail.subscription?.admin_note ?? ''}
                        placeholder="e.g. Beta reward, refund replacement"
                        class="w-full bg-paper border border-rule rounded px-2 py-1 text-sm"
                    />
                </div>
                <button
                    type="submit"
                    class="px-4 py-2 rounded bg-ember text-paper font-medium hover:bg-ember-hot"
                >
                    {detail.subscription?.source === 'admin' ? 'Extend' : 'Grant'}
                </button>
            </div>
        </form>

        {#if detail.subscription && detail.subscription.status !== 'revoked'}
            <form method="post" action="?/revoke" class="border-t border-rule pt-4 mt-4">
                <button
                    type="submit"
                    class="px-4 py-2 rounded border border-destructive/50 text-destructive hover:bg-destructive/10"
                    onclick={(e: MouseEvent) => {
                        if (!confirm('Revoke this user\'s subscription?')) e.preventDefault();
                    }}
                >
                    Revoke subscription
                </button>
            </form>
        {/if}
    </div>

    <!-- Usage -->
    <div class="bg-paper-alt border border-rule rounded p-5 mb-6">
        <h3 class="text-xl italic mb-3">AI usage</h3>
        <div class="grid sm:grid-cols-2 gap-4">
            {#each [detail.usage.this_period, detail.usage.previous_period] as period}
                <div class="border border-rule rounded p-3 bg-paper">
                    <div class="flex items-baseline justify-between mb-2">
                        <span class="font-mono text-sm">{period.period}</span>
                        <span class="text-ember font-mono">{money(period.estimated_cost_usd)}</span>
                    </div>
                    {#if Object.keys(period.totals).length === 0}
                        <p class="text-xs text-ink-faint">No usage.</p>
                    {:else}
                        <dl class="grid grid-cols-[1fr_max-content] gap-x-4 gap-y-1 text-sm">
                            {#each Object.entries(period.totals) as [action, count]}
                                <dt class="text-ink-soft">{action.replaceAll('_', ' ')}</dt>
                                <dd class="font-mono">{count}</dd>
                            {/each}
                            <dt class="text-ink-soft font-medium border-t border-rule pt-1">total</dt>
                            <dd class="font-mono font-medium border-t border-rule pt-1">{period.total}</dd>
                        </dl>
                    {/if}
                </div>
            {/each}
        </div>
    </div>

    <!-- Inventory -->
    <div class="bg-paper-alt border border-rule rounded p-5">
        <h3 class="text-xl italic mb-3">Inventory</h3>
        <div class="grid grid-cols-3 gap-3 text-center">
            <div class="border border-rule rounded p-3 bg-paper">
                <div class="text-2xl font-mono">{detail.inventory.recipes}</div>
                <div class="text-xs text-ink-soft uppercase tracking-wider mt-1">Recipes</div>
            </div>
            <div class="border border-rule rounded p-3 bg-paper">
                <div class="text-2xl font-mono">{detail.inventory.weeks}</div>
                <div class="text-xs text-ink-soft uppercase tracking-wider mt-1">Weeks planned</div>
            </div>
            <div class="border border-rule rounded p-3 bg-paper">
                <div class="text-2xl font-mono">{detail.inventory.active_push_devices}</div>
                <div class="text-xs text-ink-soft uppercase tracking-wider mt-1">Push devices</div>
            </div>
        </div>
    </div>
</section>
