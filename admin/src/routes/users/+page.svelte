<script lang="ts">
    import type { PageData } from './$types';

    let { data }: { data: PageData } = $props();

    function statusLabel(status: string) {
        if (!status) return 'free';
        return status;
    }

    function relativeDate(iso: string) {
        const d = new Date(iso);
        return d.toISOString().slice(0, 10);
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
                        <th class="py-2 pl-4 text-right">{data.period} usage</th>
                    </tr>
                </thead>
                <tbody>
                    {#each data.users as user}
                        <tr class="border-t border-rule">
                            <td class="py-2 pr-4">{user.email || '(no email)'}</td>
                            <td class="py-2 pr-4 text-ink-soft">{user.display_name || '—'}</td>
                            <td class="py-2 pr-4">
                                <span
                                    class="text-xs px-2 py-0.5 rounded {user.subscription_status === 'active'
                                        ? 'bg-success/20 text-success'
                                        : 'bg-paper-alt text-ink-soft'}"
                                >
                                    {statusLabel(user.subscription_status)}
                                </span>
                            </td>
                            <td class="py-2 pr-4 text-ink-faint font-mono">
                                {relativeDate(user.created_at)}
                            </td>
                            <td class="py-2 pl-4 text-right font-mono text-ember">
                                {user.monthly_usage}
                            </td>
                        </tr>
                    {/each}
                </tbody>
            </table>
        </div>
    {/if}
</section>
