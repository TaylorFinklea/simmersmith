import { error, fail } from '@sveltejs/kit';
import { adminApi, AdminApiError, type SubscriptionAction } from '$lib/server/api';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ platform, params }) => {
    try {
        return await adminApi.user(platform, params.id);
    } catch (err) {
        if (err instanceof AdminApiError) {
            if (err.status === 404) throw error(404, 'User not found');
            throw error(err.status === 403 ? 403 : 502, err.message);
        }
        throw err;
    }
};

export const actions: Actions = {
    grant_pro: async ({ request, platform, params }) => {
        const form = await request.formData();
        const until = (form.get('until') as string | null)?.trim();
        const note = (form.get('note') as string | null)?.trim() || undefined;
        if (!until) return fail(400, { error: 'Pick an expiration date.' });
        try {
            const body: SubscriptionAction = { action: 'grant_pro', until };
            if (note) body.note = note;
            await adminApi.subscriptionOverride(platform, params.id, body);
            return { ok: true, message: `Granted Pro until ${until}.` };
        } catch (err) {
            if (err instanceof AdminApiError) {
                return fail(err.status, { error: err.body || err.message });
            }
            return fail(500, { error: String(err) });
        }
    },

    revoke: async ({ platform, params }) => {
        try {
            await adminApi.subscriptionOverride(platform, params.id, { action: 'revoke' });
            return { ok: true, message: 'Subscription revoked.' };
        } catch (err) {
            if (err instanceof AdminApiError) {
                return fail(err.status, { error: err.body || err.message });
            }
            return fail(500, { error: String(err) });
        }
    }
};
