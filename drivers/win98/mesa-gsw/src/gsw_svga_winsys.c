/* SPDX-License-Identifier: GPL-3.0-only */

#include "gsw_svga_winsys.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

struct gsw_svga_winsys_screen {
   struct svga_winsys_screen base;
   struct svga_winsys_context context;
   boolean context_leased;
   uint64_t abi_submission_count;
};

static struct gsw_svga_winsys_screen *
gsw_screen(struct svga_winsys_screen *sws)
{
   return (struct gsw_svga_winsys_screen *)sws;
}

static const struct gsw_svga_winsys_screen *
gsw_const_screen(const struct svga_winsys_screen *sws)
{
   return (const struct gsw_svga_winsys_screen *)sws;
}

static struct gsw_svga_winsys_screen *
gsw_context_screen(struct svga_winsys_context *swc)
{
   return (struct gsw_svga_winsys_screen *)((char *)swc -
      offsetof(struct gsw_svga_winsys_screen, context));
}

void
gsw_svga_winsys_screen_destroy(struct svga_winsys_screen *sws)
{
   if (sws != NULL)
      free(gsw_screen(sws));
}

static SVGA3dHardwareVersion
gsw_get_hw_version(struct svga_winsys_screen *sws)
{
   (void)sws;
   return SVGA3D_HWVERSION_WS65_B1;
}

static int
gsw_get_fd(struct svga_winsys_screen *sws)
{
   (void)sws;
   return -1;
}

static boolean
gsw_get_cap(struct svga_winsys_screen *sws, SVGA3dDevCapIndex index,
            SVGA3dDevCapResult *result)
{
   (void)sws;
   (void)index;
   if (result != NULL)
      memset(result, 0, sizeof(*result));
   return FALSE;
}

static void
gsw_context_destroy(struct svga_winsys_context *swc)
{
   if (swc != NULL)
      gsw_context_screen(swc)->context_leased = FALSE;
}

static void *
gsw_context_reserve(struct svga_winsys_context *swc, uint32_t nr_bytes,
                    uint32_t nr_relocs)
{
   (void)swc;
   (void)nr_bytes;
   (void)nr_relocs;
   return NULL;
}

static unsigned
gsw_context_command_buffer_size(struct svga_winsys_context *swc)
{
   (void)swc;
   return 0;
}

static void
gsw_surface_relocation(struct svga_winsys_context *swc, uint32 *sid,
                       uint32 *mobid, struct svga_winsys_surface *surface,
                       unsigned flags)
{
   (void)swc;
   (void)surface;
   (void)flags;
   if (sid != NULL)
      *sid = SVGA3D_INVALID_ID;
   if (mobid != NULL)
      *mobid = SVGA3D_INVALID_ID;
}

static void
gsw_region_relocation(struct svga_winsys_context *swc,
                      struct SVGAGuestPtr *ptr,
                      struct svga_winsys_buffer *buffer, uint32 offset,
                      unsigned flags)
{
   (void)swc;
   (void)buffer;
   (void)offset;
   (void)flags;
   if (ptr != NULL)
      memset(ptr, 0, sizeof(*ptr));
}

static void
gsw_shader_relocation(struct svga_winsys_context *swc, uint32 *shid,
                      uint32 *mobid, uint32 *offset,
                      struct svga_winsys_gb_shader *shader, unsigned flags)
{
   (void)swc;
   (void)shader;
   (void)flags;
   if (shid != NULL)
      *shid = SVGA3D_INVALID_ID;
   if (mobid != NULL)
      *mobid = SVGA3D_INVALID_ID;
   if (offset != NULL)
      *offset = 0;
}

static void
gsw_context_relocation(struct svga_winsys_context *swc, uint32 *cid)
{
   (void)swc;
   if (cid != NULL)
      *cid = SVGA3D_INVALID_ID;
}

static void
gsw_mob_relocation(struct svga_winsys_context *swc, SVGAMobId *id,
                   uint32 *offset_into_mob,
                   struct svga_winsys_buffer *buffer, uint32 offset,
                   unsigned flags)
{
   (void)swc;
   (void)buffer;
   (void)offset;
   (void)flags;
   if (id != NULL)
      *id = SVGA3D_INVALID_ID;
   if (offset_into_mob != NULL)
      *offset_into_mob = 0;
}

static void
gsw_query_relocation(struct svga_winsys_context *swc, SVGAMobId *id,
                     struct svga_winsys_gb_query *query)
{
   (void)swc;
   (void)query;
   if (id != NULL)
      *id = SVGA3D_INVALID_ID;
}

static enum pipe_error
gsw_query_bind(struct svga_winsys_context *swc,
               struct svga_winsys_gb_query *query, unsigned flags)
{
   (void)swc;
   (void)query;
   (void)flags;
   return PIPE_ERROR;
}

static void
gsw_context_commit(struct svga_winsys_context *swc)
{
   (void)swc;
}

static enum pipe_error
gsw_context_flush(struct svga_winsys_context *swc,
                  struct pipe_fence_handle **pfence)
{
   (void)swc;
   if (pfence != NULL)
      *pfence = NULL;
   return PIPE_ERROR;
}

static void *
gsw_context_surface_map(struct svga_winsys_context *swc,
                        struct svga_winsys_surface *surface, unsigned flags,
                        boolean *retry, boolean *rebind)
{
   (void)swc;
   (void)surface;
   (void)flags;
   if (retry != NULL)
      *retry = FALSE;
   if (rebind != NULL)
      *rebind = FALSE;
   return NULL;
}

static void
gsw_context_surface_unmap(struct svga_winsys_context *swc,
                          struct svga_winsys_surface *surface,
                          boolean *rebind)
{
   (void)swc;
   (void)surface;
   if (rebind != NULL)
      *rebind = FALSE;
}

static struct svga_winsys_gb_shader *
gsw_context_shader_create(struct svga_winsys_context *swc, uint32 shader_id,
                          SVGA3dShaderType shader_type,
                          const uint32 *bytecode, uint32 bytecode_len,
                          const SVGA3dDXShaderSignatureHeader *signature,
                          uint32 signature_len)
{
   (void)swc;
   (void)shader_id;
   (void)shader_type;
   (void)bytecode;
   (void)bytecode_len;
   (void)signature;
   (void)signature_len;
   return NULL;
}

static void
gsw_context_shader_destroy(struct svga_winsys_context *swc,
                           struct svga_winsys_gb_shader *shader)
{
   (void)swc;
   (void)shader;
}

static enum pipe_error
gsw_context_resource_rebind(struct svga_winsys_context *swc,
                            struct svga_winsys_surface *surface,
                            struct svga_winsys_gb_shader *shader,
                            unsigned flags)
{
   (void)swc;
   (void)surface;
   (void)shader;
   (void)flags;
   return PIPE_ERROR;
}

static struct svga_winsys_context *
gsw_context_create(struct svga_winsys_screen *sws)
{
   struct gsw_svga_winsys_screen *screen;

   if (sws == NULL)
      return NULL;
   screen = gsw_screen(sws);
   if (screen->context_leased)
      return NULL;
   screen->context_leased = TRUE;
   return &screen->context;
}

static struct svga_winsys_surface *
gsw_surface_create(struct svga_winsys_screen *sws,
                   SVGA3dSurfaceAllFlags flags, SVGA3dSurfaceFormat format,
                   unsigned usage, SVGA3dSize size, uint32 num_layers,
                   uint32 num_mip_levels, unsigned sample_count)
{
   (void)sws;
   (void)flags;
   (void)format;
   (void)usage;
   (void)size;
   (void)num_layers;
   (void)num_mip_levels;
   (void)sample_count;
   return NULL;
}

static struct svga_winsys_surface *
gsw_surface_from_handle(struct svga_winsys_screen *sws,
                        struct winsys_handle *handle,
                        SVGA3dSurfaceFormat *format)
{
   (void)sws;
   (void)handle;
   if (format != NULL)
      *format = SVGA3D_FORMAT_INVALID;
   return NULL;
}

static boolean
gsw_surface_get_handle(struct svga_winsys_screen *sws,
                       struct svga_winsys_surface *surface, unsigned stride,
                       struct winsys_handle *handle)
{
   (void)sws;
   (void)surface;
   (void)stride;
   (void)handle;
   return FALSE;
}

static boolean
gsw_surface_is_flushed(struct svga_winsys_screen *sws,
                       struct svga_winsys_surface *surface)
{
   (void)sws;
   (void)surface;
   return FALSE;
}

static void
gsw_surface_reference(struct svga_winsys_screen *sws,
                      struct svga_winsys_surface **destination,
                      struct svga_winsys_surface *source)
{
   (void)sws;
   (void)source;
   if (destination != NULL)
      *destination = NULL;
}

static boolean
gsw_surface_can_create(struct svga_winsys_screen *sws,
                       SVGA3dSurfaceFormat format, SVGA3dSize size,
                       uint32 num_layers, uint32 num_mip_levels,
                       uint32 num_samples)
{
   (void)sws;
   (void)format;
   (void)size;
   (void)num_layers;
   (void)num_mip_levels;
   (void)num_samples;
   return FALSE;
}

static void
gsw_surface_init(struct svga_winsys_screen *sws,
                 struct svga_winsys_surface *surface, unsigned size,
                 SVGA3dSurfaceAllFlags flags)
{
   (void)sws;
   (void)surface;
   (void)size;
   (void)flags;
}

static struct svga_winsys_buffer *
gsw_buffer_create(struct svga_winsys_screen *sws, unsigned alignment,
                  unsigned usage, unsigned size)
{
   (void)sws;
   (void)alignment;
   (void)usage;
   (void)size;
   return NULL;
}

static void *
gsw_buffer_map(struct svga_winsys_screen *sws,
               struct svga_winsys_buffer *buffer, unsigned usage)
{
   (void)sws;
   (void)buffer;
   (void)usage;
   return NULL;
}

static void
gsw_buffer_unmap(struct svga_winsys_screen *sws,
                 struct svga_winsys_buffer *buffer)
{
   (void)sws;
   (void)buffer;
}

static void
gsw_buffer_destroy(struct svga_winsys_screen *sws,
                   struct svga_winsys_buffer *buffer)
{
   (void)sws;
   (void)buffer;
}

static void
gsw_fence_reference(struct svga_winsys_screen *sws,
                    struct pipe_fence_handle **destination,
                    struct pipe_fence_handle *source)
{
   (void)sws;
   (void)source;
   if (destination != NULL)
      *destination = NULL;
}

static int
gsw_fence_signalled(struct svga_winsys_screen *sws,
                    struct pipe_fence_handle *fence, unsigned flags)
{
   (void)sws;
   (void)fence;
   (void)flags;
   return -1;
}

static int
gsw_fence_finish(struct svga_winsys_screen *sws,
                 struct pipe_fence_handle *fence, uint64_t timeout,
                 unsigned flags)
{
   (void)sws;
   (void)fence;
   (void)timeout;
   (void)flags;
   return -1;
}

static int
gsw_fence_get_fd(struct svga_winsys_screen *sws,
                 struct pipe_fence_handle *fence, boolean duplicate)
{
   (void)sws;
   (void)fence;
   (void)duplicate;
   return -1;
}

static void
gsw_fence_create_fd(struct svga_winsys_screen *sws,
                    struct pipe_fence_handle **fence, int32_t fd)
{
   (void)sws;
   (void)fd;
   if (fence != NULL)
      *fence = NULL;
}

static int
gsw_fence_server_sync(struct svga_winsys_screen *sws, int32_t *context_fd,
                      struct pipe_fence_handle *fence)
{
   (void)sws;
   (void)fence;
   if (context_fd != NULL)
      *context_fd = -1;
   return -1;
}

static struct svga_winsys_gb_shader *
gsw_shader_create(struct svga_winsys_screen *sws,
                  SVGA3dShaderType shader_type, const uint32 *bytecode,
                  uint32 bytecode_len)
{
   (void)sws;
   (void)shader_type;
   (void)bytecode;
   (void)bytecode_len;
   return NULL;
}

static void
gsw_shader_destroy(struct svga_winsys_screen *sws,
                   struct svga_winsys_gb_shader *shader)
{
   (void)sws;
   (void)shader;
}

static struct svga_winsys_gb_query *
gsw_query_create(struct svga_winsys_screen *sws, uint32 length)
{
   (void)sws;
   (void)length;
   return NULL;
}

static void
gsw_query_destroy(struct svga_winsys_screen *sws,
                  struct svga_winsys_gb_query *query)
{
   (void)sws;
   (void)query;
}

static int
gsw_query_init(struct svga_winsys_screen *sws,
               struct svga_winsys_gb_query *query, unsigned offset,
               SVGA3dQueryState state)
{
   (void)sws;
   (void)query;
   (void)offset;
   (void)state;
   return -1;
}

static void
gsw_query_get_result(struct svga_winsys_screen *sws,
                     struct svga_winsys_gb_query *query, unsigned offset,
                     SVGA3dQueryState *state, void *result,
                     uint32 result_length)
{
   (void)sws;
   (void)query;
   (void)offset;
   if (state != NULL)
      memset(state, 0, sizeof(*state));
   if (result != NULL && result_length != 0)
      memset(result, 0, result_length);
}

static void
gsw_stats_inc(struct svga_winsys_screen *sws, enum svga_stats_count count)
{
   (void)sws;
   (void)count;
}

static void
gsw_stats_time_push(struct svga_winsys_screen *sws,
                    enum svga_stats_time time,
                    struct svga_winsys_stats_timeframe *frame)
{
   (void)sws;
   (void)time;
   if (frame != NULL)
      memset(frame, 0, sizeof(*frame));
}

static void
gsw_stats_time_pop(struct svga_winsys_screen *sws)
{
   (void)sws;
}

static void
gsw_host_log(struct svga_winsys_screen *sws, const char *message)
{
   (void)sws;
   (void)message;
}

static void
gsw_init_context(struct svga_winsys_context *swc)
{
   swc->destroy = gsw_context_destroy;
   swc->reserve = gsw_context_reserve;
   swc->get_command_buffer_size = gsw_context_command_buffer_size;
   swc->surface_relocation = gsw_surface_relocation;
   swc->region_relocation = gsw_region_relocation;
   swc->shader_relocation = gsw_shader_relocation;
   swc->context_relocation = gsw_context_relocation;
   swc->mob_relocation = gsw_mob_relocation;
   swc->query_relocation = gsw_query_relocation;
   swc->query_bind = gsw_query_bind;
   swc->commit = gsw_context_commit;
   swc->flush = gsw_context_flush;
   swc->surface_map = gsw_context_surface_map;
   swc->surface_unmap = gsw_context_surface_unmap;
   swc->shader_create = gsw_context_shader_create;
   swc->shader_destroy = gsw_context_shader_destroy;
   swc->resource_rebind = gsw_context_resource_rebind;
   swc->cid = SVGA3D_INVALID_ID;
   swc->hints = 0;
   swc->imported_fence_fd = -1;
   swc->have_gb_objects = FALSE;
   swc->force_coherent = FALSE;
   swc->debug_callback = NULL;
   swc->last_command = (SVGAFifo3dCmdId)0;
   swc->num_commands = 0;
   swc->num_command_buffers = 0;
   swc->num_draw_commands = 0;
   swc->num_shader_reloc = 0;
   swc->num_surf_reloc = 0;
   swc->in_retry = 0;
}

static void
gsw_init_screen(struct svga_winsys_screen *sws)
{
   sws->destroy = gsw_svga_winsys_screen_destroy;
   sws->get_hw_version = gsw_get_hw_version;
   sws->get_fd = gsw_get_fd;
   sws->get_cap = gsw_get_cap;
   sws->context_create = gsw_context_create;
   sws->surface_create = gsw_surface_create;
   sws->surface_from_handle = gsw_surface_from_handle;
   sws->surface_get_handle = gsw_surface_get_handle;
   sws->surface_is_flushed = gsw_surface_is_flushed;
   sws->surface_reference = gsw_surface_reference;
   sws->surface_can_create = gsw_surface_can_create;
   sws->surface_init = gsw_surface_init;
   sws->buffer_create = gsw_buffer_create;
   sws->buffer_map = gsw_buffer_map;
   sws->buffer_unmap = gsw_buffer_unmap;
   sws->buffer_destroy = gsw_buffer_destroy;
   sws->fence_reference = gsw_fence_reference;
   sws->fence_signalled = gsw_fence_signalled;
   sws->fence_finish = gsw_fence_finish;
   sws->fence_get_fd = gsw_fence_get_fd;
   sws->fence_create_fd = gsw_fence_create_fd;
   sws->fence_server_sync = gsw_fence_server_sync;
   sws->shader_create = gsw_shader_create;
   sws->shader_destroy = gsw_shader_destroy;
   sws->query_create = gsw_query_create;
   sws->query_destroy = gsw_query_destroy;
   sws->query_init = gsw_query_init;
   sws->query_get_result = gsw_query_get_result;
   sws->stats_inc = gsw_stats_inc;
   sws->stats_time_push = gsw_stats_time_push;
   sws->stats_time_pop = gsw_stats_time_pop;
   sws->host_log = gsw_host_log;
   sws->have_gb_objects = false;
   sws->have_gb_dma = false;
   sws->have_coherent = false;
   sws->have_vgpu10 = FALSE;
   sws->have_sm4_1 = FALSE;
   sws->have_sm5 = FALSE;
   sws->need_to_rebind_resources = FALSE;
   sws->have_generate_mipmap_cmd = FALSE;
   sws->have_set_predication_cmd = FALSE;
   sws->have_transfer_from_buffer_cmd = FALSE;
   sws->have_fence_fd = FALSE;
   sws->have_intra_surface_copy = FALSE;
   sws->have_constant_buffer_offset_cmd = FALSE;
   sws->have_index_vertex_buffer_offset_cmd = FALSE;
   sws->have_rasterizer_state_v2_cmd = FALSE;
   sws->have_gl43 = FALSE;
   sws->device_id = 0;
}

struct svga_winsys_screen *
gsw_svga_winsys_screen_create(void)
{
   struct gsw_svga_winsys_screen *screen;

   screen = (struct gsw_svga_winsys_screen *)calloc(1, sizeof(*screen));
   if (screen == NULL)
      return NULL;
   gsw_init_screen(&screen->base);
   gsw_init_context(&screen->context);
   return &screen->base;
}

struct pipe_screen *
gsw_svga_winsys_screen_try_create(gsw_svga_screen_create_fn create_screen)
{
   struct svga_winsys_screen *sws;
   struct pipe_screen *screen;

   if (create_screen == NULL)
      return NULL;
   sws = gsw_svga_winsys_screen_create();
   if (sws == NULL)
      return NULL;
   screen = create_screen(sws);
   if (screen == NULL)
      sws->destroy(sws);
   return screen;
}

uint64_t
gsw_svga_winsys_abi_submission_count(const struct svga_winsys_screen *sws)
{
   if (sws == NULL)
      return 0;
   return gsw_const_screen(sws)->abi_submission_count;
}
