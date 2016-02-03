 /**
  - -* (C) Copyright 2013 King Abdullah University of Science and Technology
  Authors:
  Ali Charara (ali.charara@kaust.edu.sa)
  David Keyes (david.keyes@kaust.edu.sa)
  Hatem Ltaief (hatem.ltaief@kaust.edu.sa)

  Redistribution  and  use  in  source and binary forms, with or without
  modification,  are  permitted  provided  that the following conditions
  are met:

  * Redistributions  of  source  code  must  retain  the above copyright
  * notice,  this  list  of  conditions  and  the  following  disclaimer.
  * Redistributions  in  binary  form must reproduce the above copyright
  * notice,  this list of conditions and the following disclaimer in the
  * documentation  and/or other materials provided with the distribution.
  * Neither  the  name of the King Abdullah University of Science and
  * Technology nor the names of its contributors may be used to endorse
  * or promote products derived from this software without specific prior
  * written permission.
  *
  THIS  SOFTWARE  IS  PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
  ``AS IS''  AND  ANY  EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
  LIMITED  TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
  A  PARTICULAR  PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
  HOLDERS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
  SPECIAL,  EXEMPLARY,  OR  CONSEQUENTIAL  DAMAGES  (INCLUDING,  BUT NOT
  LIMITED  TO,  PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
  DATA,  OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
  THEORY  OF  LIABILITY,  WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
  (INCLUDING  NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
  OF  THIS  SOFTWARE,  EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
  **/
#include <stdlib.h>
#include <stdio.h>
#include <cuda.h>
#include <cuda_runtime.h>
#include <cuda_runtime_api.h>
#include "cublas_v2.h"
#include "kblas.h"
#include "Xtr_common.ch"
#include "operators.h"

//==============================================================================================

cublasStatus_t cublasXtrsm(cublasHandle_t handle,
                           cublasSideMode_t side, cublasFillMode_t uplo,
                           cublasOperation_t trans, cublasDiagType_t diag,
                           int m, int n,
                           const float *alpha,
                           const float *A, int lda,
                                 float *B, int ldb){
  return cublasStrsm(handle,
                     side, uplo, trans, diag,
                     m, n,
                     alpha, A, lda,
                            B, ldb );
}
cublasStatus_t cublasXtrsm(cublasHandle_t handle,
                           cublasSideMode_t side, cublasFillMode_t uplo,
                           cublasOperation_t trans, cublasDiagType_t      diag,
                           int m, int n,
                           const double *alpha,
                           const double *A, int lda,
                                 double *B, int ldb){
  return cublasDtrsm(handle,
                     side, uplo, trans, diag,
                     m, n,
                     alpha, A, lda,
                            B, ldb );
}
cublasStatus_t cublasXtrsm (cublasHandle_t handle,
                            cublasSideMode_t side, cublasFillMode_t uplo,
                            cublasOperation_t trans, cublasDiagType_t diag,
                            int m, int n,
                            const cuComplex *alpha,
                            const cuComplex *A, int lda,
                                  cuComplex *B, int ldb){
  return cublasCtrsm(handle,
                     side, uplo, trans, diag,
                     m, n,
                     alpha, A, lda,
                            B, ldb );
}
cublasStatus_t cublasXtrsm (cublasHandle_t handle,
                            cublasSideMode_t side, cublasFillMode_t uplo,
                            cublasOperation_t trans, cublasDiagType_t diag,
                            int m, int n,
                            const cuDoubleComplex *alpha,
                            const cuDoubleComplex *A, int lda,
                                  cuDoubleComplex *B, int ldb){
  return cublasZtrsm(handle,
                     side, uplo, trans, diag,
                     m, n,
                     alpha, A, lda,
                            B, ldb );
}

//==============================================================================================
#define WARP 32
#define WARP1 33
#define WARP2 34
#define tx threadIdx.x
#define ty threadIdx.y
//==============================================================================================
int kblas_trsm_ib_cublas = 128;
bool kblas_trsm_use_custom = 0;
#define SIMPLE_SIZE(n) ( ((n) < WARP) || ( ((n) % WARP == 0) && ( (n) <= kblas_trsm_ib_cublas ) ) )
//==============================================================================================
template<typename T, int WARPS_PER_BLOCK, bool LOWER, bool TRANS, bool CONJG, bool UNIT>
__global__ void //__launch_bounds__(WARP * WARPS_PER_BLOCK)
trsm_mul32_L(int M, int N, T alpha, const T* __restrict__ A, int incA, T* B, int incB, int mb)
{
  const int A_COLS_PER_WARP = WARP / WARPS_PER_BLOCK;
  const bool forward = (LOWER != TRANS);

  //setup shared memory
  __shared__ T sA[WARP * WARP1];//strided to avoid bank conflicts

  int txyw = tx + ty * WARP1, txyiA = tx + ty * incA, txyiB = tx + ty * incB, jtxw;
  int l, c, r, startB = 0, i;
  T rB, s, rBj, a[4], b[4], *sAA, *BB;

  for(startB = 0; startB < N; startB += gridDim.x * WARPS_PER_BLOCK)
  {

    if( (blockIdx.x * WARPS_PER_BLOCK + startB) >= N)
      return;

    BB = B + (blockIdx.x * WARPS_PER_BLOCK + startB) * incB;

    //checking boundary case, the column indices of B this warp is computing
    //if not active, this warp will only participate in fetching A sub-matrices, will not compute
    bool active = ( (blockIdx.x * WARPS_PER_BLOCK + startB + ty) < N );

    for(c = (forward ? 0 : mb-1); (forward && c < mb) || (!forward && c >= 0); c += (forward ? 1 : -1))
    {
      s = make_zero<T>();

      for(r = (forward ? 0 : mb-1); (forward && r < c) || (!forward && r > c); r += (forward ? 1 : -1))
      {
        //load A(r,c)
        #pragma unroll
        for(l = 0; l < A_COLS_PER_WARP; l++){
          if(TRANS)
            sA[txyw + l * WARPS_PER_BLOCK * WARP1] = A[txyiA + WARP * (r + c * incA) + l * WARPS_PER_BLOCK * incA];
          else
            sA[txyw + l * WARPS_PER_BLOCK * WARP1] = A[txyiA + WARP * (c + r * incA) + l * WARPS_PER_BLOCK * incA];
        }
        //load B(r)
        if(active)
          rB = BB[txyiB + WARP * r];

        __syncthreads();
        if(active){
          //gemm A(r,c) & B(r) onto B(c) held at s
          if(TRANS)
            sAA = sA + tx*WARP1;
          else
            sAA = sA + tx;
            #pragma unroll
            for(int j = 0; j < WARP; j+=4){
              if(TRANS){
                #pragma unroll
                for(i = 0; i < 4; i++)
                  a[i] = CONJG ? conjugate(sAA[j + i]) : sAA[j + i];
              }else{
                #pragma unroll
                for(i = 0; i < 4; i++)
                  a[i] = sAA[(j + i)*WARP1];
              }
              #pragma unroll
              for(i = 0; i < 4; i++)
                b[i] = shfl(rB, j + i);
              #pragma unroll
              for(i = 0; i < 4; i++)
                s = FMA( a[i], b[i], s );
            }
        }
        __syncthreads();
      }

      //load A(c,c) from global to shared mem
      #pragma unroll
      for(l = 0; l < A_COLS_PER_WARP; l++){
        sA[txyw + l * WARPS_PER_BLOCK * WARP1] = A[txyiA + WARP * c * (incA + 1) + l * WARPS_PER_BLOCK * incA];
      }

      //load B(c) into registers
      if(active)
        rB = BB[txyiB + WARP * c];

      __syncthreads();
      if(active)
      {
        //perform trsm on shared mem
        if(!LOWER && TRANS)
          jtxw = tx * WARP1;
        else
        if(!LOWER && !TRANS)
          jtxw = tx         + (WARP - 1) * WARP1;
        else
        if(LOWER && TRANS)
          jtxw = tx * WARP1 + (WARP - 1);
        else
        if(LOWER && !TRANS)
          jtxw = tx;

        #pragma unroll
        for(int j = (forward ? 0 : WARP-1); (forward && (j < WARP)) || (!forward && (j >= 0)); j += (forward ? 1 : -1)){
          if(j == tx){
            rB = FMA(alpha, rB, -s);//TODO
            if(!UNIT){
              a[0] = (TRANS && CONJG) ? conjugate(sA[tx * WARP2]) : sA[tx * WARP2];//diagonal element
              rB = rB / a[0];//TODO
            }
          }
          rBj = shfl(rB, j);

          if( (forward && (j < tx)) || (!forward && (j > tx)) ){
            a[0] = (TRANS && CONJG) ? conjugate(sA[jtxw]) : sA[jtxw];
            s = FMA(a[0], rBj, s);
          }
          jtxw += (TRANS ? 1 : WARP1) * (forward ? 1 : -1);
        }

        //store back B(c) to global mem
        BB[txyiB + WARP * c] = rB;
      }
      __syncthreads();
    }
  }
}
//==============================================================================================
template<class T>
cublasStatus_t Xtrsm(cublasHandle_t handle,
                     cublasSideMode_t side, cublasFillMode_t uplo,
                     cublasOperation_t trans, cublasDiagType_t diag,
                     int m, int n,
                     const T *alpha,
                     const T *A, int incA,
                           T *B, int incB){
  
  //handle odd cases with cublas
  if(  (*alpha == make_zero<T>())
    || (!kblas_trsm_use_custom)
    || (side == CUBLAS_SIDE_LEFT && m < WARP)
    || (side == CUBLAS_SIDE_RIGHT/* && n < WARP*/))//TODO
  {
    return cublasXtrsm(handle,
                       side, uplo, trans, diag,
                       m, n,
                       alpha, A, incA,
                              B, incB );
  }

  typedef void (*trsm_kernels_type)(int M, int N, T alpha, const T* A, int incA, T* B, int incB, int mb);

  #define WARPS_PER_BLOCK 8
  #define B_COLS_PER_WARP 1

  trsm_kernels_type trsm_kernels[4] = {// T, WARPS_PER_BLOCK, LOWER, TRANS, CONJG, UNIT
    trsm_mul32_L<T, WARPS_PER_BLOCK,  true, false, false, false>,
    trsm_mul32_L<T, WARPS_PER_BLOCK,  true,  true, false, false>,
    trsm_mul32_L<T, WARPS_PER_BLOCK, false, false, false, false>,
    trsm_mul32_L<T, WARPS_PER_BLOCK, false,  true, false, false>/*,TODO
    trsm_mul32_R<T, WARPS_PER_BLOCK, B_COLS_PER_WARP,  true, false, false>,
    trsm_mul32_R<T, WARPS_PER_BLOCK, B_COLS_PER_WARP,  true,  true, false>,
    trsm_mul32_R<T, WARPS_PER_BLOCK, B_COLS_PER_WARP, false, false, false>,
    trsm_mul32_R<T, WARPS_PER_BLOCK, B_COLS_PER_WARP, false,  true, false>*/
  };

  cudaStream_t curStream;
  cublasStatus_t status;

  if((status = cublasGetStream( handle, &curStream )) != CUBLAS_STATUS_SUCCESS ) return status;

  if( ((side == CUBLAS_SIDE_LEFT) && (m % WARP == 0)) /*|| ((side == CUBLAS_SIDE_RIGHT) && (n % WARP == 0))*/ )//TODO
  {
    int func_idx = /*4*(side == CUBLAS_SIDE_RIGHT) + */2*(uplo == CUBLAS_FILL_MODE_UPPER) + (trans != CUBLAS_OP_N);// + (diag == CUBLAS_DIAG_UNIT);TODO
    dim3 blockDim( WARP, WARPS_PER_BLOCK );
    dim3 gridDim(
      (side == CUBLAS_SIDE_LEFT) * (n / (WARPS_PER_BLOCK * B_COLS_PER_WARP) + (n % (WARPS_PER_BLOCK * B_COLS_PER_WARP) > 0))
      /*+TODO
      (side == CUBLAS_SIDE_RIGHT) * (m / (WARPS_PER_BLOCK * B_COLS_PER_WARP) + (m % (WARPS_PER_BLOCK * B_COLS_PER_WARP) > 0))*/
      , 1);
    int mb = (side == CUBLAS_SIDE_LEFT) * m / WARP /*+ (side == CUBLAS_SIDE_RIGHT) * n / WARP*/;//TODO
    trsm_kernels[func_idx]<<< gridDim, blockDim, 0, curStream>>> (m, n, *alpha, A, incA, B, incB, mb);
    if(!_kblas_error( (cudaGetLastError()), __func__, __FILE__, __LINE__ ))
      return CUBLAS_STATUS_EXECUTION_FAILED;
  }else{
    //error: we should not reach this case
    return CUBLAS_STATUS_INTERNAL_ERROR;
  }
  return CUBLAS_STATUS_SUCCESS;
}
//==============================================================================================
template<typename T>
cublasStatus_t kblasXtrsm(cublasHandle_t handle,
                          cublasSideMode_t side, cublasFillMode_t uplo,
                          cublasOperation_t trans, cublasDiagType_t diag,
                          int m, int n,
                          const T *alpha,
                          const T *A, int incA,
                                T *B, int incB)
{
  T one = make_one<T>();
  T mone = make_zero<T>() - one;
  T mInvAlpha = mone / *alpha;
  cublasStatus_t status;

  if(*alpha == make_zero<T>()){//TODO
    return Xtrsm(handle,
                 side, uplo, trans, diag,
                 m, n,
                 alpha, A, incA,
                        B, incB );
  }
  cublasOperation_t noTrans = CUBLAS_OP_N;//Trans = CUBLAS_OP_T,

  if(side == CUBLAS_SIDE_LEFT){

    if(SIMPLE_SIZE(m)){
      return Xtrsm(handle,
                   side, uplo, trans, diag,
                   m, n,
                   alpha, A, incA,
                          B, incB );
    }

    int m1, m2;
    if(REG_SIZE(m))
      m1 = m2 = m/2;
    else{
      m1 = CLOSEST_REG_SIZE(m);
      m2 = m-m1;
    }

    if(uplo == CUBLAS_FILL_MODE_UPPER){

      //Left / Upper / NoTrans
      if(trans == CUBLAS_OP_N){
        if((status = kblasXtrsm(handle,
                                side, uplo, trans, diag,
                                m2, n,
                                alpha, A+m1+m1*incA, incA,
                                       B+m1, incB
                                )) != CUBLAS_STATUS_SUCCESS) return status;

        if((status = cublasXgemm(handle,
                                 trans, noTrans,
                                 m1, n, m2,
                                 &mone, A+m1*incA, incA,
                                        B+m1, incB,
                                 alpha, B, incB
                                 )) != CUBLAS_STATUS_SUCCESS) return status;

        if((status = kblasXtrsm(handle,
                                side, uplo, trans, diag,
                                m1, n,
                                &one, A, incA,
                                      B, incB
                                )) != CUBLAS_STATUS_SUCCESS) return status;
      }
      //Left / Upper / [Conj]Trans
      else{
        if((status = kblasXtrsm(handle,
                                side, uplo, trans, diag,
                                m1, n,
                                alpha, A, incA,
                                       B, incB
                                )) != CUBLAS_STATUS_SUCCESS) return status;

        if((status = cublasXgemm(handle,
                                 trans, noTrans,
                                 m2, n, m1,
                                 &mone, A+m1*incA, incA,
                                        B, incB,
                                 alpha, B+m1, incB
                                 )) != CUBLAS_STATUS_SUCCESS) return status;

        if((status = kblasXtrsm(handle,
                                side, uplo, trans, diag,
                                m2, n,
                                &one, A+m1+m1*incA, incA,
                                      B+m1, incB
                                )) != CUBLAS_STATUS_SUCCESS) return status;
      }
    }else{//uplo == KBLAS_Lower

      //Left / Lower / NoTrans
      if(trans == CUBLAS_OP_N){
        if((status = kblasXtrsm(handle,
                                side, uplo, trans, diag,
                                m1, n,
                                alpha, A, incA,
                                       B, incB
                                )) != CUBLAS_STATUS_SUCCESS) return status;

        if((status = cublasXgemm(handle,
                                 trans, noTrans,
                                 m2, n, m1,
                                 &mone, A+m1, incA,
                                        B, incB,
                                 alpha, B+m1, incB
                                 )) != CUBLAS_STATUS_SUCCESS) return status;

        if((status = kblasXtrsm(handle,
                                side, uplo, trans, diag,
                                m2, n,
                                &one, A+m1+m1*incA, incA,
                                      B+m1, incB
                                )) != CUBLAS_STATUS_SUCCESS) return status;
      }
      //Left / Lower / [Conj]Trans
      else{//transa == KBLAS_Trans

        if((status = kblasXtrsm(handle,
                                side, uplo, trans, diag,
                                m2, n,
                                alpha, A+m1+m1*incA, incA,
                                       B+m1, incB
                                )) != CUBLAS_STATUS_SUCCESS) return status;

        if((status = cublasXgemm(handle,
                                 trans, noTrans,
                                 m1, n, m2,
                                 &mone, A+m1, incA,
                                        B+m1, incB,
                                 alpha, B, incB
                                 )) != CUBLAS_STATUS_SUCCESS) return status;

        if((status = kblasXtrsm(handle,
                                side, uplo, trans, diag,
                                m1, n,
                                &one, A, incA,
                                      B, incB
                                )) != CUBLAS_STATUS_SUCCESS) return status;
      }//transa == KBLAS_Trans
    }
  }
  else{//side == KBLAS_Right

    if(SIMPLE_SIZE(n)){
      return Xtrsm(handle,
                   side, uplo, trans, diag,
                   m, n,
                   alpha, A, incA,
                          B, incB );
    }

    int n1, n2;

    if(REG_SIZE(n))
      n1 = n2 = n/2;
    else{
      n1 = CLOSEST_REG_SIZE(n);
      n2 = n-n1;
    }

    if(uplo == KBLAS_Upper){
      //Right / Upper / NoTrans
      if(trans == noTrans){
        if((status = kblasXtrsm(handle,
                                side, uplo, trans, diag,
                                m, n1,
                                alpha, A, incA,
                                       B, incB
                                )) != CUBLAS_STATUS_SUCCESS) return status;

        if((status = cublasXgemm(handle,
                                 noTrans, trans,
                                 m, n2, n1,
                                 &mone, B, incB,
                                        A+n1*incA, incA,
                                 alpha, B+n1*incB, incB
                                 )) != CUBLAS_STATUS_SUCCESS) return status;

        if((status = kblasXtrsm(handle,
                                side, uplo, trans, diag,
                                m, n2,
                                &one, A+n1+n1*incA, incA,
                                      B+n1*incB, incB
                                )) != CUBLAS_STATUS_SUCCESS) return status;
      }
      //Right / Upper / [Conj]Trans
      else{
        if((status = kblasXtrsm(handle,
                                side, uplo, trans, diag,
                                m, n2,
                                alpha, A+n1+n1*incA, incA,
                                       B+n1*incB, incB
                                )) != CUBLAS_STATUS_SUCCESS) return status;

        if((status = cublasXgemm(handle,
                                 noTrans, trans,
                                 m, n1, n2,
                                 &mInvAlpha, B+n1*incB, incB,
                                             A+n1*incA, incA,
                                 &one,       B, incB
                                 )) != CUBLAS_STATUS_SUCCESS) return status;

        if((status = kblasXtrsm(handle,
                                side, uplo, trans, diag,
                                m, n1,
                                alpha, A, incA,
                                       B, incB
                                )) != CUBLAS_STATUS_SUCCESS) return status;
      }
    }
    else{
      //Right / Lower / NoTrans
      if(trans == CUBLAS_OP_N){
        if((status = kblasXtrsm(handle,
                                side, uplo, trans, diag,
                                m, n2,
                                alpha, A+n1+n1*incA, incA,
                                       B+n1*incB, incB
                                )) != CUBLAS_STATUS_SUCCESS) return status;

        if((status = cublasXgemm(handle,
                                 noTrans, trans,
                                 m, n1, n2,
                                 &mone, B+n1*incB, incB,
                                        A+n1, incA,
                                 alpha, B, incB
                                 )) != CUBLAS_STATUS_SUCCESS) return status;

        if((status = kblasXtrsm(handle,
                                side, uplo, trans, diag,
                                m, n1,
                                &one, A, incA,
                                      B, incB
                                )) != CUBLAS_STATUS_SUCCESS) return status;
      }
      //Right / Lower / [Conj]Trans
      else{
        if((status = kblasXtrsm(handle,
                                side, uplo, trans, diag,
                                m, n1,
                                alpha, A, incA,
                                       B, incB
                                )) != CUBLAS_STATUS_SUCCESS) return status;

        if((status = cublasXgemm(handle,
                                 noTrans, trans,
                                 m, n2, n1,
                                 &mInvAlpha, B, incB,
                                             A+n1, incA,
                                 &one,       B+n1*incB, incB
                                 )) != CUBLAS_STATUS_SUCCESS) return status;

        if((status = kblasXtrsm(handle,
                                side, uplo, trans, diag,
                                m, n2,
                                alpha, A+n1+n1*incA, incA,
                                       B+n1*incB, incB
                                )) != CUBLAS_STATUS_SUCCESS) return status;
      }
    }

  }//side == Right

  return CUBLAS_STATUS_SUCCESS;
}

//==============================================================================================

/*extern "C" {
  int kblas_strsm_async(
                        char side, char uplo, char trans, char diag,
                        int m, int n,
                        float alpha, const float *A, int incA,
                        float *B, int incB,
                        cudaStream_t    stream){

    check_error(cublasSetKernelStream(stream));
    return kblasXtrsm(
                      side, uplo, trans, diag,
                      m, n,
                      alpha, A, incA,
                      B, incB);
  }
  int kblas_dtrsm_async(
                        char side, char uplo, char trans, char diag,
                        int m, int n,
                        double alpha, const double *A, int incA,
                        double *B, int incB,
                        cudaStream_t    stream){

    check_error(cublasSetKernelStream(stream));
    return kblasXtrsm(
                      side, uplo, trans, diag,
                      m, n,
                      alpha, A, incA,
                      B, incB);
  }
  int kblas_ctrsm_async(
                        char side, char uplo, char trans, char diag,
                        int m, int n,
                        cuComplex alpha, const cuComplex *A, int incA,
                        cuComplex *B, int incB,
                        cudaStream_t    stream){

    check_error(cublasSetKernelStream(stream));
    return kblasXtrsm(
                      side, uplo, trans, diag,
                      m, n,
                      alpha, A, incA,
                      B, incB);
  }
  int kblas_ztrsm_async(
                        char side, char uplo, char trans, char diag,
                        int m, int n,
                        cuDoubleComplex alpha, const cuDoubleComplex *A, int incA,
                        cuDoubleComplex *B, int incB,
                        cudaStream_t    stream){

    check_error(cublasSetKernelStream(stream));
    return kblasXtrsm(
                      side, uplo, trans, diag,
                      m, n,
                      alpha, A, incA,
                      B, incB);
  }

  int kblas_strsm(
                  char side, char uplo, char trans, char diag,
                  int m, int n,
                  float alpha, const float *A, int incA,
                  float *B, int incB){
    return kblasXtrsm(
                      side, uplo, trans, diag,
                      m, n,
                      alpha, A, incA,
                      B, incB);
  }
  int kblas_dtrsm(
                  char side, char uplo, char trans, char diag,
                  int m, int n,
                  double alpha, const double *A, int incA,
                  double *B, int incB){
    return kblasXtrsm(
                      side, uplo, trans, diag,
                      m, n,
                      alpha, A, incA,
                      B, incB);
  }
  int kblas_ctrsm(
                  char side, char uplo, char trans, char diag,
                  int m, int n,
                  cuComplex alpha, const cuComplex *A, int incA,
                  cuComplex *B, int incB){
    return kblasXtrsm(
                      side, uplo, trans, diag,
                      m, n,
                      alpha, A, incA,
                      B, incB);
  }
  int kblas_ztrsm(
                  char side, char uplo, char trans, char diag,
                  int m, int n,
                  cuDoubleComplex alpha, const cuDoubleComplex *A, int incA,
                  cuDoubleComplex *B, int incB){
    return kblasXtrsm(
                      side, uplo, trans, diag,
                      m, n,
                      alpha, A, incA,
                      B, incB);
  }

}*/

//==============================================================================================

void kblasStrsm_async(char side, char uplo, char trans, char diag,
                      int m, int n,
                      float alpha, const float *A, int lda,
                                         float *B, int ldb,
                      cudaStream_t stream){

  cublasHandle_t cublas_handle;
  if( cublasCreate(&cublas_handle) != CUBLAS_STATUS_SUCCESS ) return;
  if( cublasSetStream_v2(cublas_handle, stream) != CUBLAS_STATUS_SUCCESS ){
    cublasDestroy_v2(cublas_handle);
    return;
  }
  cublasSideMode_t  side_v2  = (side  == KBLAS_Left  ? CUBLAS_SIDE_LEFT : CUBLAS_SIDE_RIGHT);
  cublasFillMode_t  uplo_v2  = (uplo  == KBLAS_Lower ? CUBLAS_FILL_MODE_LOWER : CUBLAS_FILL_MODE_UPPER);
  cublasOperation_t trans_v2 = (trans == KBLAS_Trans ? CUBLAS_OP_T : CUBLAS_OP_N);
  cublasDiagType_t  diag_v2  = (diag  == KBLAS_Unit  ? CUBLAS_DIAG_UNIT : CUBLAS_DIAG_NON_UNIT);

  kblasXtrsm(cublas_handle,
             side_v2, uplo_v2, trans_v2, diag_v2,
             m, n,
             &alpha, A, lda,
                     B, ldb);

  cublasDestroy_v2(cublas_handle);
}

void kblasDtrsm_async(char side, char uplo, char trans, char diag,
                      int m, int n,
                      double alpha, const double *A, int lda,
                                          double *B, int ldb,
                      cudaStream_t stream){

  cublasHandle_t cublas_handle;
  if( cublasCreate(&cublas_handle) != CUBLAS_STATUS_SUCCESS ) return;
  if( cublasSetStream_v2(cublas_handle, stream) != CUBLAS_STATUS_SUCCESS ){
    cublasDestroy_v2(cublas_handle);
    return;
  }
  cublasSideMode_t  side_v2  = (side  == KBLAS_Left  ? CUBLAS_SIDE_LEFT : CUBLAS_SIDE_RIGHT);
  cublasFillMode_t  uplo_v2  = (uplo  == KBLAS_Lower ? CUBLAS_FILL_MODE_LOWER : CUBLAS_FILL_MODE_UPPER);
  cublasOperation_t trans_v2 = (trans == KBLAS_Trans ? CUBLAS_OP_T : CUBLAS_OP_N);
  cublasDiagType_t  diag_v2  = (diag  == KBLAS_Unit  ? CUBLAS_DIAG_UNIT : CUBLAS_DIAG_NON_UNIT);

  kblasXtrsm(cublas_handle,
             side_v2, uplo_v2, trans_v2, diag_v2,
             m, n,
             &alpha, A, lda,
                     B, ldb);

  cublasDestroy_v2(cublas_handle);
}
void kblasCtrsm_async(char side, char uplo, char trans, char diag,
                      int m, int n,
                      cuComplex alpha, const cuComplex *A, int lda,
                                             cuComplex *B, int ldb,
                      cudaStream_t stream){

  cublasHandle_t cublas_handle;
  if( cublasCreate(&cublas_handle) != CUBLAS_STATUS_SUCCESS ) return;
  if( cublasSetStream_v2(cublas_handle, stream) != CUBLAS_STATUS_SUCCESS ){
    cublasDestroy_v2(cublas_handle);
    return;
  }
  cublasSideMode_t  side_v2  = (side  == KBLAS_Left  ? CUBLAS_SIDE_LEFT : CUBLAS_SIDE_RIGHT);
  cublasFillMode_t  uplo_v2  = (uplo  == KBLAS_Lower ? CUBLAS_FILL_MODE_LOWER : CUBLAS_FILL_MODE_UPPER);
  cublasOperation_t trans_v2 = (trans == KBLAS_Trans ? CUBLAS_OP_T : CUBLAS_OP_N);
  cublasDiagType_t  diag_v2  = (diag  == KBLAS_Unit  ? CUBLAS_DIAG_UNIT : CUBLAS_DIAG_NON_UNIT);

  kblasXtrsm(cublas_handle,
             side_v2, uplo_v2, trans_v2, diag_v2,
             m, n,
             &alpha, A, lda,
                     B, ldb);

  cublasDestroy_v2(cublas_handle);
}
void kblasZtrsm_async(char side, char uplo, char trans, char diag,
                      int m, int n,
                      cuDoubleComplex alpha, const cuDoubleComplex *A, int lda,
                                                   cuDoubleComplex *B, int ldb,
                      cudaStream_t stream){

  cublasHandle_t cublas_handle;
  if( cublasCreate(&cublas_handle) != CUBLAS_STATUS_SUCCESS ) return;
  if( cublasSetStream_v2(cublas_handle, stream) != CUBLAS_STATUS_SUCCESS ){
    cublasDestroy_v2(cublas_handle);
    return;
  }
  cublasSideMode_t  side_v2  = (side  == KBLAS_Left  ? CUBLAS_SIDE_LEFT : CUBLAS_SIDE_RIGHT);
  cublasFillMode_t  uplo_v2  = (uplo  == KBLAS_Lower ? CUBLAS_FILL_MODE_LOWER : CUBLAS_FILL_MODE_UPPER);
  cublasOperation_t trans_v2 = (trans == KBLAS_Trans ? CUBLAS_OP_T : CUBLAS_OP_N);
  cublasDiagType_t  diag_v2  = (diag  == KBLAS_Unit  ? CUBLAS_DIAG_UNIT : CUBLAS_DIAG_NON_UNIT);

  kblasXtrsm(cublas_handle,
             side_v2, uplo_v2, trans_v2, diag_v2,
             m, n,
             &alpha, A, lda,
                     B, ldb);

  cublasDestroy_v2(cublas_handle);
}
//==============================================================================================

void kblasStrsm(char side, char uplo, char trans, char diag,
                int m, int n,
                float alpha, const float *A, int lda,
                                   float *B, int ldb){

  kblasStrsm_async(side, uplo, trans, diag,
                   m, n,
                   alpha, A, lda,
                          B, ldb,
                   0);
}

void kblasDtrsm(char side, char uplo, char trans, char diag,
                int m, int n,
                double alpha, const double *A, int lda,
                                    double *B, int ldb){

  kblasDtrsm_async(side, uplo, trans, diag,
                   m, n,
                   alpha, A, lda,
                          B, ldb,
                   0);
}
void kblasCtrsm(char side, char uplo, char trans, char diag,
                int m, int n,
                cuComplex alpha, const cuComplex *A, int lda,
                                       cuComplex *B, int ldb){

  kblasCtrsm_async(side, uplo, trans, diag,
                   m, n,
                   alpha, A, lda,
                          B, ldb,
                   0);

}
void kblasZtrsm(char side, char uplo, char trans, char diag,
                int m, int n,
                cuDoubleComplex alpha, const cuDoubleComplex *A, int lda,
                                             cuDoubleComplex *B, int ldb){

  kblasZtrsm_async(side, uplo, trans, diag,
                   m, n,
                   alpha, A, lda,
                          B, ldb,
                   0);
}
//==============================================================================================

cublasStatus_t kblasStrsm(cublasHandle_t handle,
                          cublasSideMode_t side, cublasFillMode_t uplo,
                          cublasOperation_t trans, cublasDiagType_t diag,
                          int m, int n,
                          const float *alpha,
                          const float *A, int lda,
                                float *B, int ldb){
  return kblasXtrsm(handle,
                    side, uplo, trans, diag,
                    m, n,
                    alpha, A, lda,
                           B, ldb);
}
cublasStatus_t kblasDtrsm(cublasHandle_t handle,
                          cublasSideMode_t side, cublasFillMode_t uplo,
                          cublasOperation_t trans, cublasDiagType_t diag,
                          int m, int n,
                          const double *alpha,
                          const double *A, int lda,
                                double *B, int ldb){
  return kblasXtrsm(handle,
                    side, uplo, trans, diag,
                    m, n,
                    alpha, A, lda,
                           B, ldb);
}
cublasStatus_t kblasCtrsm(cublasHandle_t handle,
                          cublasSideMode_t side, cublasFillMode_t uplo,
                          cublasOperation_t trans, cublasDiagType_t diag,
                          int m, int n,
                          const cuComplex *alpha,
                          const cuComplex *A, int lda,
                                cuComplex *B, int ldb){
  return kblasXtrsm(handle,
                    side, uplo, trans, diag,
                    m, n,
                    alpha, A, lda,
                           B, ldb);
}
cublasStatus_t kblasZtrsm(cublasHandle_t handle,
                          cublasSideMode_t side, cublasFillMode_t uplo,
                          cublasOperation_t trans, cublasDiagType_t diag,
                          int m, int n,
                          const cuDoubleComplex *alpha,
                          const cuDoubleComplex *A, int lda,
                                cuDoubleComplex *B, int ldb){
  return kblasXtrsm(handle,
                    side, uplo, trans, diag,
                    m, n,
                    alpha, A, lda,
                           B, ldb);
}





