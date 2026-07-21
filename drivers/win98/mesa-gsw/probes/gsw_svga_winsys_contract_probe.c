/* SPDX-License-Identifier: GPL-3.0-only */

#include "gsw_svga_winsys.h"

int
gsw_svga_winsys_contract_probe(struct svga_winsys_screen *sws,
                               struct svga_winsys_context *swc)
{
   if (sws == NULL || swc == NULL)
      return 1;
   if (sws->destroy == NULL || sws->get_hw_version == NULL ||
       sws->get_fd == NULL || sws->get_cap == NULL ||
       sws->context_create == NULL || sws->surface_create == NULL ||
       sws->surface_from_handle == NULL || sws->surface_get_handle == NULL ||
       sws->surface_is_flushed == NULL || sws->surface_reference == NULL ||
       sws->surface_can_create == NULL || sws->surface_init == NULL ||
       sws->buffer_create == NULL || sws->buffer_map == NULL ||
       sws->buffer_unmap == NULL || sws->buffer_destroy == NULL ||
       sws->fence_reference == NULL || sws->fence_signalled == NULL ||
       sws->fence_finish == NULL || sws->fence_get_fd == NULL ||
       sws->fence_create_fd == NULL || sws->fence_server_sync == NULL ||
       sws->shader_create == NULL || sws->shader_destroy == NULL ||
       sws->query_create == NULL || sws->query_destroy == NULL ||
       sws->query_init == NULL || sws->query_get_result == NULL ||
       sws->stats_inc == NULL || sws->stats_time_push == NULL ||
       sws->stats_time_pop == NULL || sws->host_log == NULL)
      return 2;
   if (swc->destroy == NULL || swc->reserve == NULL ||
       swc->get_command_buffer_size == NULL ||
       swc->surface_relocation == NULL || swc->region_relocation == NULL ||
       swc->shader_relocation == NULL || swc->context_relocation == NULL ||
       swc->mob_relocation == NULL || swc->query_relocation == NULL ||
       swc->query_bind == NULL || swc->commit == NULL || swc->flush == NULL ||
       swc->surface_map == NULL || swc->surface_unmap == NULL ||
       swc->shader_create == NULL || swc->shader_destroy == NULL ||
       swc->resource_rebind == NULL)
      return 3;
   return 0;
}
