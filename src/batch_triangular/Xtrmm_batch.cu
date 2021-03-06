/**
 * @copyright (c) 2012- King Abdullah University of Science and
 *                      Technology (KAUST). All rights reserved.
 **/


/**
 * @file src/batch_triangular/Xtrmm_batch.cu

 * KBLAS is a high performance CUDA library for subset of BLAS
 *    and LAPACK routines optimized for NVIDIA GPUs.
 * KBLAS is provided by KAUST.
 *
 * @version 2.0.0
 * @author Ali Charara
 * @date 2017-11-13
 **/

#include <stdlib.h>
#include <stdio.h>
#include <cuda.h>
#include <cuda_runtime.h>
#include <cuda_runtime_api.h>
#include "cublas_v2.h"
#include <typeinfo>

#include "kblas.h"
#include "kblas_struct.h"
#include "operators.h"
#include "defs.h"
#include "kblas_common.h"
#include "batch_common.ch"

//==============================================================================================
#include "Xblas_core.ch"
#include "Xhelper_funcs.ch"
#include "Xtrmm_batch_drivers.cuh"

//==============================================================================================
//Non-Strided form


int Xtrmm_batch_offset( kblasHandle_t handle,
                        char side, char uplo, char trans, char diag,
                        const int m, const int n,
                        const TYPE alpha,
                        const TYPE** A, int A_row_off, int A_col_off, int lda,
                              TYPE** B, int B_row_off, int B_col_off, int ldb,
                        int batchCount){

  KBlasWorkspaceState ws_needed;
  trmm_batch_wsquery_core<false>( batchCount,
                                  side, m, n,
                                  (kblasWorkspaceState_t)&ws_needed);

  if( !ws_needed.isSufficient( &(handle->work_space.allocated_ws_state) ) ){
    return KBLAS_InsufficientWorkspace;
  }

  return Xtrmm_batch_core<TYPE, TYPE**, false>(
                          handle,
                          side, uplo, trans, diag,
                          m, n,
                          alpha,
                          (TYPE**)A, A_row_off, A_col_off, lda, (long)0,
                          (TYPE**)B, B_row_off, B_col_off, ldb, (long)0,
                          batchCount);
}

// workspace needed: device pointers
// A, B: host pointer to array of device pointers to device buffers
int kblas_trmm_batch(kblasHandle_t handle,
                     char side, char uplo, char trans, char diag,
                     const int m, const int n,
                     const TYPE alpha,
                     const TYPE** A, int lda,
                           TYPE** B, int ldb,
                    int batchCount)
{
  return Xtrmm_batch_offset(handle,
                            side, uplo, trans, diag,
                            m, n,
                            alpha,
                            A, 0, 0, lda,
                            B, 0, 0, ldb,
                            batchCount);
}


// workspace needed: device pointers
// A, B: host pointer to array of device pointers to device buffers
extern "C"
int kblasXtrmm_batch(kblasHandle_t handle,
                     char side, char uplo, char trans, char diag,
                     const int m, const int n,
                     const TYPE alpha,
                     const TYPE** A, int lda,
                           TYPE** B, int ldb,
                    int batchCount)
{
  return Xtrmm_batch_offset(handle,
                            side, uplo, trans, diag,
                            m, n,
                            alpha,
                            A, 0, 0, lda,
                            B, 0, 0, ldb,
                            batchCount);
}


//==============================================================================================
//Strided form

int Xtrmm_batch_offset( kblasHandle_t handle,
                        char side, char uplo, char trans, char diag,
                        const int m, const int n,
                        const TYPE alpha,
                        const TYPE* A, int A_row_off, int A_col_off, int lda, long strideA,
                              TYPE* B, int B_row_off, int B_col_off, int ldb, long strideB,
                        int batchCount){

  KBlasWorkspaceState ws_needed;
  trmm_batch_wsquery_core<true>(batchCount,
                                side, m, n,
                                (kblasWorkspaceState_t)&ws_needed);

  bool suffWorkspace = (ws_needed.d_ptrs_bytes <= handle->work_space.allocated_ws_state.d_ptrs_bytes);

  if(!suffWorkspace){
    return KBLAS_InsufficientWorkspace;
  }

  return Xtrmm_batch_core<TYPE, TYPE*, true>(
                          handle,
                          side, uplo, trans, diag,
                          m, n,
                          alpha,
                          (TYPE*)A, A_row_off, A_col_off, lda, strideA,
                          (TYPE*)B, B_row_off, B_col_off, ldb, strideB,
                          batchCount);
}

// workspace needed: device pointers
// A, B: host pointer to array of device pointers to device buffers
int kblas_trmm_batch(kblasHandle_t handle,
                     char side, char uplo, char trans, char diag,
                     const int m, const int n,
                     const TYPE alpha,
                     const TYPE* A, int lda, long strideA,
                           TYPE* B, int ldb, long strideB,
                    int batchCount)
{
  return Xtrmm_batch_offset(handle,
                            side, uplo, trans, diag,
                            m, n,
                            alpha,
                            A, 0, 0, lda, strideA,
                            B, 0, 0, ldb, strideB,
                            batchCount);
}


// workspace needed: device pointers
// A, B: host pointer to device buffers
extern "C"
int kblasXtrmm_batch_strided(kblasHandle_t handle,
                             char side, char uplo, char trans, char diag,
                             const int m, const int n,
                             const TYPE alpha,
                             const TYPE* A, int lda, long strideA,
                                   TYPE* B, int ldb, long strideB,
                             int batchCount)
{
  return Xtrmm_batch_offset(handle,
                            side, uplo, trans, diag,
                            m, n,
                            alpha,
                            A, 0, 0, lda, strideA,
                            B, 0, 0, ldb, strideB,
                            batchCount);
}

