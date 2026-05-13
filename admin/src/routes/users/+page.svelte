<script lang="ts">
    import type { PageData } from './$types';

    let { data }: { data: PageData } = $props();

    function statusLabel(status: string, source: string) {
        if (!status) return 'free';
        if (source === 'admin') return `${status} · admin`;
        return status;
    }

    function relativeDate(iso: string) {
        const d = new Date(iso);
        return d.toISOString().slice(0, 10);
    }

    function money(n: number) {
        return `$${n.toFixed(2)}`;
    }
</script>

<section>
    <h2 class="text-3xl italic mb-1">users</h2>
    <div class="hand-rule w-24 mb-6"></div>
    <p class="text-sm text-ink-soft mb-6">
        Every signed-up account. The "{data.period}" column shows usage accrued this month
        across all gated actions combined.
    </p>

    {#if data.users.length === 0}
        <p class="text-ink-soft">No users yet.</p>
    {:else}
        <div class="overflow-x-auto">
            <table class="w-full text-sm">
                <thead class="text-left text-ink-soft uppercase tracking-wider text-xs">
                    <tr>
                        <th class="py-2 pr-4">Email</th>
                        <th class="py-2 pr-4">Display name</th>
                        <th class="py-2 pr-4">Status</th>
                        <th class="py-2 pr-4">Created</th>
                        <th class="py-2 px-4 text-right">{data.period} usage</th>
                        <th class="py-2 pl-4 text-right">Est. spend</th>
                    </tr>
                </thead>
                <tbody>
                    {#each data.users as user}
                        <tr class="border-t border-rule hover:bg-paper-alt/60 cursor-pointer">
                            <td class="py-2 pr-4">
                                <a href="/users/{user.user_id}" class="hover:text-ember">
                                    {user.email || '(no email)'}
                                </a>
                            </td>
                            <td class="py-2 pr-4 text-ink-soft">
                                <a href="/users/{user.user_id}">{user.display_name || '—'}</a>
                            </td>
                            <td class="py-2 pr-4">
                                <span
                                    class="text-xs px-2 py-0.5 rounded {user.subscription_source === 'admin'
                                        ? 'bg-ember/20 text-ember'
                                        : user.subscription_status === 'active'
                                            ? 'bg-success/20 text-success'
                                            : 'bg-paper-alt text-ink-soft'}"
                                >
                                    {statusLabel(user.subscription_status, user.subscription_source)}
                                </span>
                            </td>
                            <td class="py-2 pr-4 text-ink-faint font-mono">
                                <a href="/users/{user.user_id}">{relativeDate(user.created_at)}</a>
                            </td>
                            <td class="py-2 px-4 text-right font-mono text-ember">
                                <a href="/users/{user.user_id}">{user.monthly_usage}</a>
                            </td>
                            <td class="py-2 pl-4 text-right font-mono text-ink-soft">
                                <a href="/users/{user.user_id}">{money(user.estimated_cost_usd)}</a>
                            </td>
                        </tr>
                    {/each}
                </tbody>
            </table>
        </div>
    {/if}
</section>
