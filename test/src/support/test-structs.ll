; ModuleID = 'test-structs.bc'
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v64:64:64-v128:128:128-a0:0:64-s0:64:64-f80:128:128-n8:16:32:64"
target triple = "x86_64-apple-darwin10.0.0"

%0 = type { i32, i8, [3 x i8] }
%1 = type { i32, [6 x i8], [2 x i8] }
%struct.A = type { i32, i8 }
%struct.B = type { i32, [6 x i8] }

@struct_test.b = internal constant %0 { i32 99, i8 122, [3 x i8] undef }, align 4
@struct_test_two.x = internal constant %1 { i32 1, [6 x i8] c"fredd\00", [2 x i8] undef }, align 4

declare void @llvm.memcpy.p0i8.p0i8.i64(i8* nocapture, i8* nocapture, i64, i32, i1) nounwind

define %struct.A @struct_test() nounwind ssp {
  %1 = alloca %struct.A, align 4
  %a = alloca %struct.A, align 4
  %b = alloca %struct.A, align 4
  %2 = getelementptr inbounds %struct.A* %a, i32 0, i32 0
  store i32 42, i32* %2, align 4
  %3 = getelementptr inbounds %struct.A* %a, i32 0, i32 1
  store i8 113, i8* %3, align 1

;  *%a = (42,113)

  %4 = bitcast %struct.A* %b to i8*
  call void @llvm.memcpy.p0i8.p0i8.i64(i8* %4, i8* bitcast (%0* @struct_test.b to i8*), i64 8, i32 4, i1 false)

; *%b = (99, 122)

  %5 = getelementptr inbounds %struct.A* %a, i32 0, i32 0
  %6 = load i32* %5, align 4

; %6 = 42

  %7 = getelementptr inbounds %struct.A* %b, i32 0, i32 0
  store i32 %6, i32* %7, align 4

; *%b = (42,122)

  %8 = bitcast %struct.A* %1 to i8*
  %9 = bitcast %struct.A* %b to i8*
  call void @llvm.memcpy.p0i8.p0i8.i64(i8* %8, i8* %9, i64 8, i32 4, i1 false)

; *%1 = (42,122)

  %10 = load %struct.A* %1, align 1

  ret %struct.A %10
}

define i32 @struct_test_two_aux(%struct.B* %bs) nounwind ssp {
  %1 = alloca %struct.B*, align 8
  %sum = alloca i32, align 4
  %i = alloca i32, align 4
  store %struct.B* %bs, %struct.B** %1, align 8
  store i32 0, i32* %sum, align 4
  store i32 0, i32* %i, align 4
  br label %2

; <label>:2                                       ; preds = %12, %0
  %3 = load i32* %i, align 4
  %4 = icmp slt i32 %3, 3
  br i1 %4, label %5, label %15

; <label>:5                                       ; preds = %2
  %6 = load %struct.B** %1, align 8
  %7 = getelementptr inbounds %struct.B* %6, i64 0
  %8 = getelementptr inbounds %struct.B* %7, i32 0, i32 0
  %9 = load i32* %8, align 4
  %10 = load i32* %sum, align 4
  %11 = add nsw i32 %10, %9
  store i32 %11, i32* %sum, align 4
  br label %12

; <label>:12                                      ; preds = %5
  %13 = load i32* %i, align 4
  %14 = add nsw i32 %13, 1
  store i32 %14, i32* %i, align 4
  br label %2

; <label>:15                                      ; preds = %2
  %16 = load i32* %sum, align 4
  ret i32 %16
}

define i32 @struct_test_two() nounwind ssp {
  %x = alloca %struct.B, align 4
  %rest = alloca [3 x %struct.B], align 16
  %i = alloca i32, align 4
  %1 = bitcast %struct.B* %x to i8*
  call void @llvm.memcpy.p0i8.p0i8.i64(i8* %1, i8* bitcast (%1* @struct_test_two.x to i8*), i64 12, i32 4, i1 false)
  store i32 0, i32* %i, align 4
  br label %2

; <label>:2                                       ; preds = %17, %0
  %3 = load i32* %i, align 4
  %4 = icmp slt i32 %3, 3
  br i1 %4, label %5, label %20

; <label>:5                                       ; preds = %2
  %6 = load i32* %i, align 4
  %7 = sext i32 %6 to i64
  %8 = getelementptr inbounds [3 x %struct.B]* %rest, i32 0, i64 %7
  %9 = bitcast %struct.B* %8 to i8*
  %10 = bitcast %struct.B* %x to i8*
  call void @llvm.memcpy.p0i8.p0i8.i64(i8* %9, i8* %10, i64 12, i32 4, i1 false)
  %11 = load i32* %i, align 4
  %12 = sext i32 %11 to i64
  %13 = getelementptr inbounds [3 x %struct.B]* %rest, i32 0, i64 %12
  %14 = getelementptr inbounds %struct.B* %13, i32 0, i32 0
  %15 = load i32* %14, align 4
  %16 = add nsw i32 %15, 1
  store i32 %16, i32* %14, align 4
  br label %17

; <label>:17                                      ; preds = %5
  %18 = load i32* %i, align 4
  %19 = add nsw i32 %18, 1
  store i32 %19, i32* %i, align 4
  br label %2

; <label>:20                                      ; preds = %2
  %21 = getelementptr inbounds [3 x %struct.B]* %rest, i32 0, i32 0
  %22 = call i32 @struct_test_two_aux(%struct.B* %21)
  %23 = icmp eq i32 6, %22
  %24 = zext i1 %23 to i32
  ret i32 %24
}
