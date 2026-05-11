import { error } from '@sveltejs/kit';
import { adminApi, AdminApiError } from '$lib/server/api';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ platform, url }) => {
    const period = url.searchParams.get('period') ?? undefined;
    try {
        const usage = await adminApi.usage(platform, period);
        return { usage };
    } catch (err) {
        if (err instanceof AdminApiError) {
            throw error(err.status === 403 ? 403 : 502, err.message);
        }
        throw err;
    }
};
